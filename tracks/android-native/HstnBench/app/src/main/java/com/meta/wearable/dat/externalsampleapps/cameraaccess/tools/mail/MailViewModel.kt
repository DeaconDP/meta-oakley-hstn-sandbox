// MailViewModel - the mail reader: what is this letter, then read it all
//
//   "what is this letter" / "read" ─► capturePage (GA in-stream photo) ─► ImageCheck (instant:
//   covered, dark, nothing in view) ─► MailOcr (ML Kit, on the phone) ─► FramingCheck (no text,
//   blurred, too small, cut off) ─► LetterReader (sender, recipient, kind, subject, amount due,
//   deadline, references; the money rule) ─► LetterSpeech summary, spoken.
// "read it all" reads every paragraph sentence by sentence (SpeechChunker) through hub.speak, so
// "stop", "carry on", "back", "skip", "say that again" and "start again" act on sentences. Questions
// ("who's it from", "how much", "when is it due", "is it junk", "what's the reference") are answered
// from the letter; asked before any letter, they photograph one first. "next page" adds a page and
// the summary updates; "how much" on an unsure amount takes a fresh, closer photo of the same page.
// The letter's text goes to hub.recentText for "ask about the text". Every failure is spoken with
// the error earcon; a soft tick plays while it works. See notes/mail-reader.md.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.mail

import android.app.Application
import android.graphics.Bitmap
import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.meta.wearable.dat.externalsampleapps.cameraaccess.R
import com.meta.wearable.dat.externalsampleapps.cameraaccess.bench.BenchClock
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.FramingCheck
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.FramingIssue
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.ImageCheck
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.ImageIssue
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.OcrLine
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.OcrPage
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.SpeechChunk
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.SpeechChunker
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.TextDistance
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.Earcon
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.OpenReason
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolHub
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolTexts
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolViewModel
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.GlobalCommand
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.HealthAlert
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.Phrases
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolRequest
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

enum class MailPhase { IDLE, LOOKING, READY, READING, PAUSED }

/** What the mail screen shows, beyond ToolUiState. */
data class MailState(
    val phase: MailPhase = MailPhase.IDLE,
    val letter: Letter? = null,
    val summary: String = "",
    val sentence: String = "",
    val sentenceIndex: Int = 0,
    val sentenceCount: Int = 0,
)

class MailViewModel(application: Application, hub: ToolHub) :
    ToolViewModel(application, hub, ToolId.MAIL) {

  companion object {
    private const val TAG = "MailReader"
    private const val TICK_MS = 1_500L
    private const val STILL_WORKING_MS = 6_000L
    private const val TAG_SENTENCE = "mail"
    /** Below this character error rate, a "next page" photo is the same page again. */
    private const val SAME_PAGE_CER = 0.3f
  }

  private enum class Mode { NEW, ADD_PAGE, RECHECK, ENVELOPE }

  private val _mail = MutableStateFlow(MailState())
  val mail: StateFlow<MailState> = _mail.asStateFlow()

  private val ocr = MailOcr()
  private var scans: List<LetterScan> = emptyList()
  private var chunks: List<SpeechChunk> = emptyList()
  private var chunkIndex = 0
  private var captureJob: Job? = null

  private val letter: Letter?
    get() = _mail.value.letter

  override fun texts(): ToolTexts =
      ToolTexts.generic(getApplication(), R.string.mail_name, R.string.mail_help)
          .copy(welcome = str(R.string.mail_name) + ". " + str(R.string.mail_welcome))

  override fun onOpened(request: ToolRequest, reason: OpenReason) {
    say(if (reason == OpenReason.TAPPED) texts().welcome else str(R.string.mail_welcome))
  }

  /** "read my mail" while already open: look at what's held up now. */
  override fun onRequest(request: ToolRequest) {
    super.onRequest(request)
    handle(MailCommand.Summarise)
  }

  override fun onLeaving() {
    captureJob?.cancel()
    if (_mail.value.phase == MailPhase.READING) {
      hub.hush()
      _mail.update { it.copy(phase = MailPhase.PAUSED) }
    }
    hub.recentText.setCurrent(ToolId.MAIL, null)
  }

  override fun isBusy(): Boolean = _mail.value.phase == MailPhase.READING

  override fun onCommand(text: String): Boolean {
    val command = MailGrammar.parse(Phrases.normalize(text)) ?: return false
    Log.i(TAG, "voice heard=\"$text\" command=$command")
    handle(command)
    return true
  }

  override fun onGlobal(command: GlobalCommand): Boolean {
    val phase = _mail.value.phase
    when (command) {
      GlobalCommand.Pause -> {
        if (phase != MailPhase.READING) return false
        pauseReading()
      }
      GlobalCommand.Resume ->
          when (phase) {
            MailPhase.PAUSED -> resumeReading()
            MailPhase.READY -> hub.reply(str(R.string.mail_nothing_to_resume))
            else -> return false
          }
      GlobalCommand.Repeat ->
          when (phase) {
            MailPhase.READING, MailPhase.PAUSED -> {
              hub.earcons.play(Earcon.ACK)
              hub.hush()
              startReading(sentenceStart(chunkIndex))
            }
            else -> return false
          }
      else -> return false
    }
    return true
  }

  override fun isWaitingForUser(): Boolean = _mail.value.phase.let { it == MailPhase.IDLE || it == MailPhase.READY || it == MailPhase.PAUSED }

  override fun reminder(index: Int, last: Boolean): String {
    val what =
        str(
            when (_mail.value.phase) {
              MailPhase.READY -> R.string.mail_nudge_ready
              MailPhase.PAUSED -> R.string.mail_nudge_paused
              else -> R.string.mail_nudge_idle
            },
        )
    return if (last) what + " " + str(R.string.mail_nudge_last) else what
  }

  override fun onHealthAlert(alert: HealthAlert): String? {
    when (alert) {
      HealthAlert.GlassesRemoved, HealthAlert.GlassesDisconnected, HealthAlert.GlassesTooHot ->
          if (_mail.value.phase == MailPhase.READING) {
            hub.hush()
            _mail.update { it.copy(phase = MailPhase.PAUSED) }
          }
      else -> Unit
    }
    return super.onHealthAlert(alert)
  }

  override fun onStreamLost(): Boolean {
    val wasLooking = captureJob?.isActive == true
    captureJob?.cancel()
    if (wasLooking) _mail.update { it.copy(phase = if (letter == null) MailPhase.IDLE else MailPhase.READY) }
    // Reading a letter already photographed doesn't need the camera, so reading carries on;
    // ToolHub still says the camera stopped and reconnects.
    return true
  }

  // MARK: - Commands (voice and buttons)

  fun handle(command: MailCommand) {
    val l = letter
    val phase = _mail.value.phase
    when (command) {
      MailCommand.Summarise ->
          if (phase == MailPhase.PAUSED && l != null) resumeReading() else capture(Mode.NEW)
      MailCommand.NewLetter -> capture(Mode.NEW)
      MailCommand.Envelope -> capture(Mode.ENVELOPE)
      MailCommand.NextPage -> if (l == null) capture(Mode.NEW) else capture(Mode.ADD_PAGE)
      MailCommand.Summary -> if (l == null) capture(Mode.NEW) else answer(LetterSpeech.summary(l))
      MailCommand.ReadAll, MailCommand.StartAgain ->
          if (l == null) capture(Mode.NEW, then = MailCommand.ReadAll) else {
            hub.earcons.play(Earcon.ACK)
            hub.hush()
            startReading(0)
          }
      MailCommand.HowMuch ->
          when {
            l == null -> capture(Mode.NEW, then = command)
            // An unsure amount: take a fresh, closer look at the same page, never guess.
            l.amount == AmountDue.Unsure || l.amount == AmountDue.Conflict -> capture(Mode.RECHECK, then = command)
            else -> answer(LetterSpeech.howMuch(l))
          }
      MailCommand.From, MailCommand.For, MailCommand.WhenDue, MailCommand.IsJunk, MailCommand.Kind,
      MailCommand.Date, MailCommand.Reference ->
          if (l == null) capture(Mode.NEW, then = command) else answer(answerFor(command, l))
      MailCommand.Back -> back()
      MailCommand.Skip -> skip()
    }
  }

  private fun answerFor(command: MailCommand, l: Letter): String =
      when (command) {
        MailCommand.From -> LetterSpeech.from(l)
        MailCommand.For -> LetterSpeech.forWhom(l)
        MailCommand.HowMuch -> LetterSpeech.howMuch(l)
        MailCommand.WhenDue -> LetterSpeech.whenDue(l)
        MailCommand.IsJunk -> LetterSpeech.isJunk(l)
        MailCommand.Kind -> LetterSpeech.kind(l)
        MailCommand.Date -> LetterSpeech.date(l)
        MailCommand.Reference -> LetterSpeech.references(l)
        else -> LetterSpeech.summary(l)
      }

  /** Answer now; reading (if any) carries on afterwards (onAsideDone). */
  private fun answer(text: String) {
    hub.reply(text)
  }

  // MARK: - Photographing and reading the letter

  private fun capture(mode: Mode, then: MailCommand? = null) {
    if (captureJob?.isActive == true) {
      hub.reply(str(R.string.mail_still_looking))
      return
    }
    if (!hub.camera.isStreaming.value) {
      if (!hub.reconnectThen { capture(mode, then) }) hub.explainNoGlasses()
      return
    }
    stopReading()
    _mail.update { it.copy(phase = MailPhase.LOOKING) }
    onStatus(str(R.string.mail_status_looking))
    hub.earcons.play(Earcon.ACK)
    hub.hush()
    hub.sayAside(str(if (mode == Mode.ADD_PAGE) R.string.mail_looking_page else R.string.mail_looking))
    captureJob = viewModelScope.launch {
      val ticker = launch {
        var waited = 0L
        var said = false
        while (true) {
          delay(TICK_MS)
          waited += TICK_MS
          hub.earcons.play(Earcon.WORKING)
          if (!said && waited >= STILL_WORKING_MS && !hub.isSpeakingAside) {
            said = true
            hub.sayAside(str(R.string.mail_still_working))
          }
        }
      }
      var done = false
      try {
        BenchClock.start("mail_capture_to_summary")
        val bitmap = hub.camera.capturePage()
        if (bitmap == null) {
          fail(R.string.mail_capture_failed)
          return@launch
        }
        val issue = withContext(Dispatchers.Default) { imageIssue(bitmap) }
        if (issue != null && issue.blocksOcr) {
          Log.i(TAG, "image_issue=$issue")
          fail(imageHint(issue))
          return@launch
        }
        val started = System.nanoTime()
        val scan = withContext(Dispatchers.Default) { ocr.recognize(bitmap) }
        BenchClock.note("metric=mail_ocr ms=${(System.nanoTime() - started) / 1_000_000} size=${bitmap.width}x${bitmap.height} lines=${scan.lines.size}")
        logScan(scan)
        val framing = FramingCheck.check(toOcrPage(scan))
        if (framing.isUnreadable) {
          Log.i(TAG, "framing=${framing.issues}")
          fail(
              if (issue != null && ImageCheck.explainsFramingFailure(issue, framing.issues)) imageHint(issue)
              else str(
                  when {
                    FramingIssue.LOW_CONFIDENCE in framing.issues -> R.string.mail_low_confidence
                    FramingIssue.TOO_SMALL in framing.issues -> R.string.mail_too_small
                    else -> R.string.mail_no_text
                  },
              ),
          )
          return@launch
        }
        val previous = scans
        val newScans =
            when (mode) {
              Mode.NEW, Mode.ENVELOPE -> listOf(scan)
              Mode.ADD_PAGE -> {
                val last = previous.lastOrNull()
                if (last != null && TextDistance.cer(last.text, scan.text) < SAME_PAGE_CER) {
                  ticker.cancel()
                  hub.earcons.play(Earcon.SAME_PAGE)
                  _mail.update { it.copy(phase = MailPhase.READY) }
                  onStatus(str(R.string.mail_same_page))
                  hub.hush()
                  hub.sayAside(str(R.string.mail_same_page))
                  done = true
                  return@launch
                }
                previous + scan
              }
              Mode.RECHECK -> if (previous.isEmpty()) listOf(scan) else previous.dropLast(1) + scan
            }
        val read = withContext(Dispatchers.Default) { LetterReader.read(newScans) }
        ticker.cancel()
        scans = newScans
        publish(read, fresh = mode == Mode.NEW || mode == Mode.ENVELOPE)
        val summary = LetterSpeech.summary(read)
        _mail.update { it.copy(phase = MailPhase.READY, letter = read, summary = summary) }
        onStatus(str(R.string.mail_status_ready))
        Log.i(TAG, "letter kind=${read.kind} envelope=${read.isEnvelope} from=${read.sender} to=${read.recipient} amount=${read.amount} due=${read.due} pages=${read.pages.size}")
        hub.earcons.play(Earcon.FOUND)
        hub.hush()
        val cut = cutOffHint(framing.issues)
        val text =
            when {
              mode == Mode.ENVELOPE -> LetterSpeech.envelope(read)
              then == MailCommand.ReadAll -> null
              then != null -> answerFor(then, read)
              mode == Mode.ADD_PAGE -> str(R.string.mail_page_added, newScans.size) + " " + summary
              else -> summary
            }
        if (text != null) hub.sayAside(listOfNotNull(text, cut).joinToString(" "))
        if (then == MailCommand.ReadAll) startReading(0)
        done = true
        BenchClock.end("mail_capture_to_summary")
      } catch (e: CancellationException) {
        throw e
      } catch (e: Exception) {
        Log.e(TAG, "Mail OCR failed", e)
        fail(R.string.mail_ocr_failed)
      } finally {
        ticker.cancel()
        if (!done && _mail.value.phase == MailPhase.LOOKING) {
          _mail.update { it.copy(phase = if (letter == null) MailPhase.IDLE else MailPhase.READY) }
        }
      }
    }
  }

  private fun publish(read: Letter, fresh: Boolean) {
    val recent = hub.recentText
    if (fresh) recent.clear(ToolId.MAIL)
    recent.addPassage(ToolId.MAIL, read.fullText, key = "letter")
    recent.setTitle(ToolId.MAIL, read.sender?.let { str(R.string.mail_title, it) })
  }

  private fun cutOffHint(issues: List<FramingIssue>): String? =
      when {
        FramingIssue.TOO_CLOSE in issues -> str(R.string.mail_too_close)
        FramingIssue.CUT_RIGHT in issues -> str(R.string.mail_cut_right)
        FramingIssue.CUT_LEFT in issues -> str(R.string.mail_cut_left)
        FramingIssue.CUT_TOP in issues -> str(R.string.mail_cut_top)
        FramingIssue.CUT_BOTTOM in issues -> str(R.string.mail_cut_bottom)
        else -> null
      }

  private fun fail(id: Int) = fail(str(id))

  private fun fail(text: String) {
    _mail.update { it.copy(phase = if (letter == null) MailPhase.IDLE else MailPhase.READY) }
    hub.warn(text)
  }

  private fun toOcrPage(scan: LetterScan): OcrPage =
      OcrPage.ofLines(scan.width, scan.height, scan.lines.map { OcrLine(it.text, it.box, it.confidence) })

  private fun logScan(scan: LetterScan) {
    for (l in scan.lines) {
      val low = l.words.mapNotNull { w -> (w.symbolConfidences.minOrNull() ?: w.confidence)?.let { w.text to it } }.minByOrNull { it.second }
      Log.i(TAG, "ocr b=${l.block} box=${l.box.left.toInt()},${l.box.top.toInt()},${l.box.right.toInt()},${l.box.bottom.toInt()} conf=${l.confidence} low=$low \"${l.text}\"")
      if (LetterText.money(l.text).isNotEmpty()) {
        for (w in l.words) {
          val chars = w.text.indices.joinToString(" ") { i ->
            val b = w.symbolBoxes.getOrNull(i)
            "${w.text[i]}:${w.symbolConfidences.getOrNull(i)?.let { "%.2f".format(it) }}@${b?.left?.toInt()}-${b?.right?.toInt()}"
          }
          Log.i(TAG, "ocr money word=\"${w.text}\" conf=${w.confidence} $chars")
        }
      }
    }
  }

  private fun imageIssue(bitmap: Bitmap): ImageIssue? {
    val src = if (bitmap.config == Bitmap.Config.HARDWARE) bitmap.copy(Bitmap.Config.ARGB_8888, false) ?: return null else bitmap
    val gw = 48
    val gh = 72
    val luma = IntArray(gw * gh)
    for (y in 0 until gh) for (x in 0 until gw) {
      val c = src.getPixel(x * src.width / gw + src.width / (2 * gw), y * src.height / gh + src.height / (2 * gh))
      luma[y * gw + x] = (0.299 * ((c shr 16) and 0xff) + 0.587 * ((c shr 8) and 0xff) + 0.114 * (c and 0xff)).toInt()
    }
    return ImageCheck.check(luma, gw, gh)
  }

  private fun imageHint(issue: ImageIssue): String =
      str(
          when (issue) {
            ImageIssue.COVERED -> R.string.mail_hint_covered
            ImageIssue.TOO_DARK -> R.string.mail_hint_dark
            else -> R.string.mail_hint_nothing
          },
      )

  // MARK: - Reading every word

  private fun startReading(from: Int) {
    val l = letter ?: return
    chunks = SpeechChunker.chunk(l.readingParagraphs)
    if (chunks.isEmpty()) {
      hub.warn(str(R.string.mail_no_text))
      return
    }
    chunkIndex = from.coerceIn(0, chunks.size - 1)
    _mail.update { it.copy(phase = MailPhase.READING, sentenceCount = chunks.size) }
    onStatus(str(R.string.mail_status_reading))
    speakCurrent()
  }

  private fun speakCurrent() {
    if (_mail.value.phase != MailPhase.READING) return
    val chunk = chunks.getOrNull(chunkIndex)
    if (chunk == null) {
      finishedReading()
      return
    }
    _mail.update { it.copy(sentence = chunk.text, sentenceIndex = chunkIndex) }
    hub.recentText.setCurrent(ToolId.MAIL, chunk.sentenceText)
    if (!hub.isSpeakingAside) hub.speak(chunk.text, TAG_SENTENCE)
  }

  override fun onSpoken(tag: String) {
    if (tag != TAG_SENTENCE || _mail.value.phase != MailPhase.READING) return
    chunkIndex++
    speakCurrent()
  }

  /** A reply or note finished: carry on reading where it was. */
  override fun onAsideDone() {
    if (_mail.value.phase == MailPhase.READING) speakCurrent()
  }

  private fun finishedReading() {
    hub.earcons.play(Earcon.PAGE_DONE)
    hub.recentText.setCurrent(ToolId.MAIL, null)
    _mail.update { it.copy(phase = MailPhase.READY, sentence = "") }
    chunkIndex = 0
    say(str(R.string.mail_end))
  }

  private fun pauseReading() {
    hub.hush()
    _mail.update { it.copy(phase = MailPhase.PAUSED) }
    onStatus(str(R.string.mail_status_paused))
    hub.sayAside(str(R.string.mail_paused))
  }

  private fun resumeReading() {
    hub.earcons.play(Earcon.ACK)
    hub.hush()
    startReading(sentenceStart(chunkIndex))
  }

  private fun stopReading() {
    if (_mail.value.phase == MailPhase.READING || _mail.value.phase == MailPhase.PAUSED) {
      hub.hush()
      hub.recentText.setCurrent(ToolId.MAIL, null)
      _mail.update { it.copy(phase = MailPhase.READY, sentence = "") }
    }
  }

  private fun sentenceStart(at: Int): Int {
    val c = chunks.getOrNull(at) ?: return 0
    return chunks.indexOfFirst { it.sentence == c.sentence }.coerceAtLeast(0)
  }

  private fun back() {
    val phase = _mail.value.phase
    if (phase != MailPhase.READING && phase != MailPhase.PAUSED) {
      if (letter == null) hub.reply(str(R.string.mail_no_letter)) else handle(MailCommand.ReadAll)
      return
    }
    hub.earcons.play(Earcon.ACK)
    hub.hush()
    val target = SpeechChunker.previousSentenceStart(chunks, chunkIndex)
    if (target == chunkIndex) hub.sayAside(str(R.string.mail_at_start))
    startReading(target)
  }

  private fun skip() {
    val phase = _mail.value.phase
    if (phase != MailPhase.READING && phase != MailPhase.PAUSED) {
      if (letter == null) hub.reply(str(R.string.mail_no_letter)) else hub.reply(str(R.string.mail_nothing_to_resume))
      return
    }
    hub.earcons.play(Earcon.ACK)
    hub.hush()
    val current = chunks.getOrNull(chunkIndex)?.sentence ?: return
    val next = chunks.indexOfFirst { it.sentence > current }
    if (next < 0) {
      chunkIndex = chunks.size
      _mail.update { it.copy(phase = MailPhase.READING) }
      finishedReading()
    } else {
      startReading(next)
    }
  }

  // MARK: - Buttons

  fun pressSummarise() { hub.userActed(); handle(MailCommand.NewLetter) }

  fun pressReadAll() { hub.userActed(); handle(MailCommand.ReadAll) }

  fun pressPauseOrResume() {
    hub.userActed()
    when (_mail.value.phase) {
      MailPhase.READING -> pauseReading()
      MailPhase.PAUSED -> resumeReading()
      else -> handle(MailCommand.ReadAll)
    }
  }

  fun pressBack() { hub.userActed(); back() }

  fun pressNextPage() { hub.userActed(); handle(MailCommand.NextPage) }

  fun pressHowMuch() { hub.userActed(); handle(MailCommand.HowMuch) }

  override fun onCleared() {
    super.onCleared()
    ocr.close()
  }

  class Factory(private val application: Application, private val hub: ToolHub) :
      ViewModelProvider.Factory {
    override fun <T : ViewModel> create(modelClass: Class<T>): T {
      @Suppress("UNCHECKED_CAST")
      return MailViewModel(application, hub) as T
    }
  }
}
