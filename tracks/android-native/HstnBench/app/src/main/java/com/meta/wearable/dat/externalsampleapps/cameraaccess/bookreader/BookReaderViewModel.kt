// BookReaderViewModel - the read-a-book loop
//
//   frame sizes ─► FrameSizeMotion ─► PageTurnDetector ─┐   (or the Next page button)
//                                                       ▼
//   capturePage (GA in-stream photo) ─► ML Kit OCR ─► PageProcessor (framing, layout, dedup)
//        ├─ Read      ─► queue the page's chunks; speak now if idle
//        ├─ SamePage  ─► earcon (and a spoken note if the user asked for it)
//        └─ Hint      ─► speak the framing hint, retry; read anyway after MAX_HINTS
//
// Capture and OCR of page N+1 run while page N is being spoken, so the next page is ready (or
// queued) when this one ends. All state lives on the main thread; OCR runs on Default.
// A bookmark (pages read + last sentence) is saved after every sentence so a fold, which ends the
// DAT session, can resume where it stopped.
//
// Voice is the primary control, not an extra: a blind reader can't see the buttons. The voice-first
// machinery every tool shares lives in tools/ToolHub (the reader is one ToolHost): listening
// (glasses mic first, phone fallback), the echo guard, connecting and narrating each step on a
// voice-first launch, spoken pitfalls, silence reminders, switching to another tool by voice, and
// questions about the text. This class keeps what is specific to reading: the book grammar
// (book/VoiceCommands, tried before the global one), the page loop, the bookmark, and the reading
// position. Replies interrupt the sentence being read and then read it again (onAsideDone), so the
// user never waits for a long sentence to finish. Each page and the sentence being read are
// published to ToolHub.recentText for "ask about the text".

package com.meta.wearable.dat.externalsampleapps.cameraaccess.bookreader

import android.app.Application
import android.content.Context
import android.util.Log
import androidx.annotation.StringRes
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.meta.wearable.dat.externalsampleapps.cameraaccess.R
import com.meta.wearable.dat.externalsampleapps.cameraaccess.bench.BenchClock
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.Bookmark
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ask.AskGrammar
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ask.AskMemory
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.FrameSignal
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.FrameSizeMotion
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.PageOutcome
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.PageProcessor
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.PageTurnDetector
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.SpeechChunk
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.SpeechChunker
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.TurnEvent
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.VoiceCommand
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.VoiceCommands
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.CameraLink
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.Earcon
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.Microphone
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.OpenReason
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolHost
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolHub
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolTexts
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.BatteryLevel
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.GlobalCommand
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.HealthAlert
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.ImageCheck
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.ImageIssue
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

enum class ReaderPhase {
  /** Not started. */
  IDLE,
  /** Running, nothing to read: waiting for a page turn or Next page. */
  WAITING,
  /** Running and speaking a page. */
  READING,
  /** Paused by the user; position kept. */
  PAUSED,
}

/** What the last capture turned out to be. Shown on screen and asserted by tests. */
enum class CaptureResult {
  NONE,
  READ,
  SAME_PAGE,
  HINT,
  FAILED,
}

data class BookReaderUiState(
    val phase: ReaderPhase = ReaderPhase.IDLE,
    val isCapturing: Boolean = false,
    val status: String = "",
    val pageText: String = "",
    val chunks: List<String> = emptyList(),
    val currentChunk: Int = -1,
    val pagesRead: Int = 0,
    val queuedPages: Int = 0,
    val lastResult: CaptureResult = CaptureResult.NONE,
    val speechRate: Float = 1f,
    val readFurniture: Boolean = false,
    val autoTurn: Boolean = true,
    val speechAvailable: Boolean = true,
    /** Which microphone voice control is using. */
    val microphone: Microphone = Microphone.NONE,
    /** Last thing the user said (final transcript), shown on screen. */
    val heard: String = "",
    /** The user asked to leave by voice; the screen closes. */
    val closeRequested: Boolean = false,
) {
  val isRunning: Boolean
    get() = phase == ReaderPhase.WAITING || phase == ReaderPhase.READING
}

class BookReaderViewModel(
    application: Application,
    private val hub: ToolHub,
) : AndroidViewModel(application), ToolHost {

  override val toolId = ToolId.BOOK
  private val camera = hub.camera

  companion object {
    private const val TAG = "BookReader"
    private const val PREFS = "book_reader"
    private const val KEY_BOOKMARK = "bookmark"
    private const val KEY_RATE = "speech_rate"
    private const val KEY_FURNITURE = "read_furniture"
    private const val KEY_AUTO = "auto_turn"
    private const val MAX_HINTS = 3
    private const val HINT_RETRY_MS = 2500L
    private const val TICK_MS = 2_500L
    private const val STILL_WORKING_MS = 10_000L
    const val MIN_RATE = 0.5f
    const val MAX_RATE = 3f
  }

  private class Page(val chunks: List<SpeechChunk>, val displayText: String)

  private val prefs = application.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

  private val _uiState =
      MutableStateFlow(
          BookReaderUiState(
              speechRate = prefs.getFloat(KEY_RATE, 1f),
              readFurniture = prefs.getBoolean(KEY_FURNITURE, false),
              autoTurn = prefs.getBoolean(KEY_AUTO, true),
          ),
      )
  val uiState: StateFlow<BookReaderUiState> = _uiState.asStateFlow()

  private val processor = PageProcessor()
  private val detector = PageTurnDetector()
  private val motion = FrameSizeMotion()
  private val ocr = MlKitOcr()
  private val earcons = hub.earcons

  // Main thread only.
  private var current: Page? = null
  private var chunkIndex = 0
  private val queue = ArrayDeque<Page>()
  private var captureJob: Job? = null
  private var retryJob: Job? = null
  private var hintAttempts = 0
  private var pendingResume: Bookmark? = null
  private var lastPage: Page? = null
  private var pageSerial = 0

  /** A short note is being spoken; the page waits for it (ToolHub owns the flag). */
  private val speakingAside: Boolean
    get() = hub.isSpeakingAside

  init {
    // Page-turn detection from the stream. Cheap per frame; events hop to main.
    viewModelScope.launch(Dispatchers.Default) {
      camera.frameSizes.collect { frame ->
        val change = motion.onFrame(frame.bytes, frame.isCodecConfig) ?: return@collect
        val event = synchronized(detector) { detector.onFrame(FrameSignal(change)) }
        if (event != null) withContext(Dispatchers.Main) { onTurnEvent(event) }
      }
    }
    // Which mic ToolHub is listening on, for the screen.
    viewModelScope.launch { hub.microphone.collect { m -> _uiState.update { it.copy(microphone = m) } } }
  }

  // MARK: - Controls

  /** The one big button: start, pause or resume. */
  fun startOrPause() {
    when (_uiState.value.phase) {
      ReaderPhase.IDLE -> start()
      ReaderPhase.PAUSED -> resume()
      ReaderPhase.WAITING, ReaderPhase.READING -> pause()
    }
  }

  fun start() {
    userActed()
    if (!camera.isStreaming.value) {
      // "read" is also how to retry after a dropped or refused connection.
      reconnectThen { start() }
      return
    }
    // A fresh start: the page in view may be the one the bookmark is on, so it must not be
    // rejected as "same page"; the bookmark decides where to pick up instead.
    processor.reset()
    queue.clear()
    current = null
    hintAttempts = 0
    pendingResume = Bookmark.decode(prefs.getString(KEY_BOOKMARK, null))
    _uiState.update {
      it.copy(phase = ReaderPhase.WAITING, pagesRead = pendingResume?.pagesRead ?: 0)
    }
    sayAside(str(R.string.book_say_started))
    requestCapture(manual = true)
  }

  fun pause() {
    userActed()
    hush()
    retryJob?.cancel()
    saveBookmark()
    _uiState.update { it.copy(phase = ReaderPhase.PAUSED, status = str(R.string.book_status_paused)) }
  }

  fun resume() {
    userActed()
    if (current != null) {
      _uiState.update { it.copy(phase = ReaderPhase.READING) }
      speakCurrent()
    } else {
      _uiState.update { it.copy(phase = ReaderPhase.WAITING) }
      if (queue.isEmpty()) {
        // Nothing captured to carry on with (e.g. after the glasses dropped out): read what's in
        // front of the camera now, reconnecting first if needed.
        hintAttempts = 0
        requestCapture(manual = true)
      } else {
        startNextPageOrWait()
      }
    }
  }

  /** "I've turned the page": capture now. Works whether or not auto-detection is on. */
  fun nextPage() {
    userActed()
    if (_uiState.value.phase == ReaderPhase.IDLE) {
      start()
      return
    }
    if (_uiState.value.phase == ReaderPhase.PAUSED) {
      _uiState.update { it.copy(phase = ReaderPhase.WAITING) }
    }
    hintAttempts = 0
    requestCapture(manual = true)
  }

  fun backSentence() {
    userActed()
    val page = current ?: return
    chunkIndex = SpeechChunker.previousSentenceStart(page.chunks, chunkIndex)
    publishChunk()
    if (_uiState.value.phase == ReaderPhase.READING) {
      hush()
      speakCurrent()
    }
  }

  /** A button press or command: acknowledge it, and start silence reminders over. */
  private fun userActed() = hub.userActed()

  fun setSpeechRate(rate: Float) {
    val r = (Math.round(rate * 10f) / 10f).coerceIn(MIN_RATE, MAX_RATE)
    hub.setRate(r)
    prefs.edit().putFloat(KEY_RATE, r).apply()
    _uiState.update { it.copy(speechRate = r) }
  }

  fun setReadFurniture(enabled: Boolean) {
    prefs.edit().putBoolean(KEY_FURNITURE, enabled).apply()
    _uiState.update { it.copy(readFurniture = enabled) }
  }

  fun setAutoTurn(enabled: Boolean) {
    prefs.edit().putBoolean(KEY_AUTO, enabled).apply()
    synchronized(detector) { detector.reset() }
    _uiState.update { it.copy(autoTurn = enabled) }
  }

  /** Leaves the reader: stop speaking, keep the bookmark. */
  fun stop() {
    if (_uiState.value.phase == ReaderPhase.IDLE) return
    hush()
    captureJob?.cancel()
    retryJob?.cancel()
    saveBookmark()
    synchronized(detector) { detector.reset() }
    _uiState.update {
      it.copy(phase = ReaderPhase.IDLE, isCapturing = false, status = str(R.string.book_status_stopped))
    }
  }

  // MARK: - Page turns and capture

  private fun onTurnEvent(event: TurnEvent) {
    if (!_uiState.value.autoTurn || !_uiState.value.isRunning) {
      if (event is TurnEvent.Capture) synchronized(detector) { detector.captureDone() }
      return
    }
    when (event) {
      TurnEvent.TurnStarted -> earcons.play(Earcon.TURN_DETECTED)
      TurnEvent.Settling -> Unit
      is TurnEvent.Capture -> {
        hintAttempts = 0
        requestCapture(manual = false)
      }
    }
  }

  private fun requestCapture(manual: Boolean, force: Boolean = false) {
    if (captureJob?.isActive == true) return
    if (!camera.isStreaming.value) {
      reconnectThen { requestCapture(manual, force) }
      return
    }
    retryJob?.cancel()
    synchronized(detector) { detector.nextPage() }
    _uiState.update { it.copy(isCapturing = true, status = str(R.string.book_status_capturing)) }
    captureJob = viewModelScope.launch {
      // Never silent while working: a soft tick every few seconds, and a word if it's slow and
      // nothing else is being read.
      val ticker = launch {
        var waited = 0L
        var said = false
        while (true) {
          delay(TICK_MS)
          waited += TICK_MS
          earcons.play(Earcon.WORKING)
          if (!said && waited >= STILL_WORKING_MS && current == null && !speakingAside) {
            said = true
            sayAside(str(R.string.book_say_still_working))
          }
        }
      }
      try {
        BenchClock.start("book_capture_to_text")
        val bitmap = camera.capturePage()
        if (bitmap == null) {
          fail(R.string.book_error_capture_failed)
          return@launch
        }
        // Instant brightness check: a covered lens, a dark room or no page in view is said now,
        // not after seconds of OCR.
        val issue = withContext(Dispatchers.Default) { imageIssue(bitmap) }
        if (issue != null) Log.i(TAG, "image_issue=$issue")
        if (issue != null && issue.blocksOcr && !force) {
          ticker.cancel()
          hint(imageHint(issue), manual)
          return@launch
        }
        val started = System.nanoTime()
        val page = withContext(Dispatchers.Default) { ocr.recognize(bitmap) }
        val ocrMs = (System.nanoTime() - started) / 1_000_000
        BenchClock.note("metric=book_ocr ms=$ocrMs size=${bitmap.width}x${bitmap.height} lines=${page.lines.size}")
        ticker.cancel()
        val outcome = processor.process(page, _uiState.value.readFurniture, forceRead = force)
        if (
            outcome is PageOutcome.Hint &&
                ImageCheck.explainsFramingFailure(issue, outcome.framing.issues)
        ) {
          hint(imageHint(issue!!), manual)
        } else {
          handleOutcome(outcome, manual)
        }
        BenchClock.end("book_capture_to_text")
      } catch (e: CancellationException) {
        throw e
      } catch (e: Exception) {
        Log.e(TAG, "Book page OCR failed", e)
        fail(R.string.book_error_ocr_failed)
      } finally {
        ticker.cancel()
        synchronized(detector) { detector.captureDone() }
        _uiState.update { it.copy(isCapturing = false) }
      }
    }
  }

  private fun handleOutcome(outcome: PageOutcome, manual: Boolean) {
    when (outcome) {
      is PageOutcome.Read -> {
        earcons.play(Earcon.PAGE_CAPTURED)
        hintAttempts = 0
        Log.i(TAG, "result=read chunks=${outcome.chunks.size} text=${outcome.displayText.take(80)}")
        val page = Page(outcome.chunks, outcome.displayText)
        queue.addLast(page)
        _uiState.update {
          it.copy(
              lastResult = CaptureResult.READ,
              queuedPages = queue.size,
              // Show the newly captured page right away if nothing else is on screen.
              pageText = if (current == null) page.displayText else it.pageText,
          )
        }
        if (current == null && _uiState.value.phase != ReaderPhase.PAUSED) startNextPageOrWait()
      }
      is PageOutcome.SamePage -> {
        earcons.play(Earcon.SAME_PAGE)
        Log.i(TAG, "result=same_page similarity=${outcome.similarity}")
        _uiState.update {
          it.copy(lastResult = CaptureResult.SAME_PAGE, status = str(R.string.book_status_same_page))
        }
        // Only speak it if the user asked for this capture and isn't listening to a page.
        if (manual && current == null) sayAside(str(R.string.book_say_same_page))
      }
      is PageOutcome.Hint -> {
        Log.i(TAG, "result=hint issues=${outcome.framing.issues}")
        hint(outcome.framing.hint ?: str(R.string.book_error_ocr_failed), manual)
      }
    }
  }

  /** A framing or image problem: say how to fix it, retry, and give up clearly after MAX_HINTS. */
  private fun hint(text: String, manual: Boolean) {
    hintAttempts++
    Log.i(TAG, "hint attempt=$hintAttempts text=$text")
    earcons.play(Earcon.ERROR)
    _uiState.update { it.copy(lastResult = CaptureResult.HINT, status = text) }
    // Don't talk over a page being read; the next capture will repeat the hint if needed.
    if (current == null) sayAside(text)
    if (!_uiState.value.isRunning) return
    if (hintAttempts < MAX_HINTS) {
      retryJob = viewModelScope.launch {
        delay(HINT_RETRY_MS)
        // The last retry reads whatever is in view, cut off or not.
        requestCapture(manual, force = hintAttempts == MAX_HINTS - 1)
      }
    } else if (current == null) {
      // Out of retries with nothing to read: say so, rather than going quiet.
      sayAside(str(R.string.book_say_cant_see_page))
      _uiState.update { it.copy(phase = ReaderPhase.WAITING) }
    }
  }

  private fun imageIssue(bitmap: android.graphics.Bitmap): ImageIssue? {
    val src =
        if (bitmap.config == android.graphics.Bitmap.Config.HARDWARE) {
          bitmap.copy(android.graphics.Bitmap.Config.ARGB_8888, false) ?: return null
        } else {
          bitmap
        }
    val gw = 48
    val gh = 72
    val luma = IntArray(gw * gh)
    for (y in 0 until gh) for (x in 0 until gw) {
      val c = src.getPixel(x * src.width / gw + src.width / (2 * gw), y * src.height / gh + src.height / (2 * gh))
      luma[y * gw + x] =
          (0.299 * ((c shr 16) and 0xff) + 0.587 * ((c shr 8) and 0xff) + 0.114 * (c and 0xff)).toInt()
    }
    return ImageCheck.check(luma, gw, gh)
  }

  private fun imageHint(issue: ImageIssue): String =
      str(
          when (issue) {
            ImageIssue.COVERED -> R.string.book_hint_covered
            ImageIssue.TOO_DARK -> R.string.book_hint_dark
            ImageIssue.NOTHING_IN_VIEW -> R.string.book_hint_nothing
            ImageIssue.GLARE -> R.string.book_hint_glare
            ImageIssue.PARTLY_BLOCKED -> R.string.book_hint_blocked
          },
      )

  // MARK: - Speaking

  private fun startNextPageOrWait() {
    val next = queue.removeFirstOrNull()
    if (next == null) {
      current = null
      if (_uiState.value.isRunning) {
        _uiState.update {
          it.copy(
              phase = ReaderPhase.WAITING,
              queuedPages = 0,
              status = pageDonePrompt(),
          )
        }
      }
      return
    }
    current = next
    chunkIndex = 0
    // Pages read this session, for questions about the text.
    hub.recentText.addPassage(ToolId.BOOK, next.displayText, key = "page-${pageSerial++}")
    pendingResume?.let { bookmark ->
      pendingResume = null
      bookmark.resumeIndex(next.chunks)?.let { idx ->
        chunkIndex = idx.coerceAtMost(next.chunks.size)
        if (idx > 0) sayAside(str(R.string.book_say_resuming))
      }
    }
    _uiState.update {
      it.copy(
          phase = ReaderPhase.READING,
          pageText = next.displayText,
          chunks = next.chunks.map(SpeechChunk::text),
          queuedPages = queue.size,
          status = str(R.string.book_status_reading),
      )
    }
    speakCurrent()
  }

  private fun speakCurrent() {
    val page = current ?: return
    if (chunkIndex >= page.chunks.size) {
      pageFinished()
      return
    }
    publishChunk()
    if (!speakingAside) hub.speak(page.chunks[chunkIndex].text, "chunk")
  }

  private fun publishChunk() {
    _uiState.update { it.copy(currentChunk = chunkIndex) }
    hub.recentText.setCurrent(ToolId.BOOK, current?.chunks?.getOrNull(chunkIndex)?.sentenceText)
  }

  /** Short spoken note (status, hint). Reading resumes after it. */
  private fun sayAside(text: String) = hub.sayAside(text)

  /** A short note ended: carry on reading where it was. */
  override fun onAsideDone() {
    if (_uiState.value.phase == ReaderPhase.READING) speakCurrent()
  }

  override fun onSpoken(tag: String) {
    if (tag != "chunk") return
    if (_uiState.value.phase != ReaderPhase.READING) return
    val page = current ?: return
    chunkIndex++
    saveBookmark(page.chunks.getOrNull(chunkIndex - 1))
    speakCurrent()
  }

  override fun onEngineState(available: Boolean) {
    // ToolHub plays the error earcon when there's no voice at all.
    _uiState.update { it.copy(speechAvailable = available) }
  }

  private fun pageFinished() {
    _uiState.update { it.copy(pagesRead = it.pagesRead + 1) }
    lastPage = current
    current = null
    if (queue.isEmpty()) {
      earcons.play(Earcon.PAGE_DONE)
      // Say what happens next, unless the next page is already being captured.
      if (captureJob?.isActive != true) sayAside(pageDonePrompt())
    }
    startNextPageOrWait()
  }

  private fun pageDonePrompt(): String =
      str(if (_uiState.value.autoTurn) R.string.book_status_turn_page else R.string.book_status_press_next)

  // MARK: - ToolHost: voice, reminders, pitfalls (the machinery is in ToolHub)

  override fun texts(): ToolTexts =
      ToolTexts(
          name = str(R.string.book_reader_title),
          connecting = str(R.string.voice_connecting),
          ready = str(R.string.voice_welcome_ready),
          welcome = str(R.string.voice_welcome_short),
          welcomeAfterSwitch = str(R.string.voice_welcome_after_switch),
          help = str(R.string.voice_help),
          streamLost = str(R.string.book_status_stream_lost),
          pausedByGlasses = str(R.string.book_say_paused_by_glasses),
          cameraBack = str(R.string.book_say_glasses_back),
          cameraDenied = str(R.string.voice_camera_denied),
          goodbye = str(R.string.voice_goodbye),
      )

  override fun speechRate(): Float = _uiState.value.speechRate

  override fun onAttached(request: ToolRequest) {
    _uiState.update { it.copy(closeRequested = false) }
  }

  /** Switching to another tool by voice: stop reading and keep the bookmark. */
  override fun onLeaving() = stop()

  override fun onDetached() {
    _uiState.update { it.copy(microphone = Microphone.NONE) }
  }

  override fun onHeard(text: String) {
    _uiState.update { it.copy(heard = text) }
  }

  override fun onStatus(text: String) {
    _uiState.update { it.copy(status = text) }
  }

  /**
   * Barge-in: stop talking on the partial, don't wait for the recogniser to finish. A question
   * about the text ("what does recondite mean") pauses too, silently: the answer follows, then
   * "carry on" reads on from the interrupted sentence.
   */
  override fun onPartial(text: String): Boolean {
    if (_uiState.value.phase == ReaderPhase.READING && VoiceCommands.isBargeIn(text)) {
      Log.i(TAG, "voice barge-in on partial: \"$text\"")
      voicePause()
      return true
    }
    if (_uiState.value.phase == ReaderPhase.READING && AskGrammar.isQuestion(text)) {
      Log.i(TAG, "voice barge-in on question partial: \"$text\"")
      pause()
      return true
    }
    return false
  }

  /** The book grammar, tried before the global one. */
  override fun onCommand(text: String): Boolean {
    val command = VoiceCommands.parse(text)
    Log.i(TAG, "voice heard=\"$text\" command=$command")
    if (command == null) return false
    handle(command)
    return true
  }

  /**
   * Global commands the book grammar didn't catch. The everyday ones mean the same as the book's
   * own; opening another tool and questions about the text are left to ToolHub.
   */
  override fun onGlobal(command: GlobalCommand): Boolean {
    when (command) {
      GlobalCommand.Pause -> handle(VoiceCommand.Pause)
      GlobalCommand.Resume -> handle(VoiceCommand.Resume)
      GlobalCommand.Repeat -> handle(VoiceCommand.Repeat)
      is GlobalCommand.Faster -> handle(VoiceCommand.Faster(command.step))
      is GlobalCommand.Slower -> handle(VoiceCommand.Slower(command.step))
      is GlobalCommand.SetRate -> handle(VoiceCommand.SetRate(command.rate))
      GlobalCommand.Help -> handle(VoiceCommand.Help)
      GlobalCommand.Battery -> handle(VoiceCommand.Battery)
      GlobalCommand.Close -> handle(VoiceCommand.Close)
      // "Main menu", "close the app": ToolHub leaves the reader (onLeaving keeps the bookmark).
      GlobalCommand.Home, GlobalCommand.ExitApp -> return false
      is GlobalCommand.Open -> {
        // "Read a book" in the book reader: same as "read".
        if (command.request.tool != ToolId.BOOK) return false
        handle(VoiceCommand.Resume)
      }
      is GlobalCommand.Ask -> {
        // Stay paused after the answer (follow-ups like "more" or "spell it" may come); "carry on"
        // reads on. ToolHub answers.
        if (_uiState.value.phase == ReaderPhase.READING) pause()
        return false
      }
    }
    return true
  }

  // While a page is being read, unknown speech is most likely the room, not the user.
  override fun onNotUnderstood(text: String) =
      hub.sayNotUnderstood(text, busy = _uiState.value.phase == ReaderPhase.READING)

  /** Nothing to read, nothing in progress: only the user can move things on. */
  override fun isWaitingForUser(): Boolean {
    val ui = _uiState.value
    return (ui.phase == ReaderPhase.IDLE || ui.phase == ReaderPhase.WAITING) &&
        !ui.closeRequested &&
        !ui.isCapturing &&
        current == null &&
        queue.isEmpty() &&
        captureJob?.isActive != true &&
        retryJob?.isActive != true
  }

  /** What the reader is waiting for, after a silence (ToolHub's IdleNudge spaces these out). */
  override fun reminder(index: Int, last: Boolean): String {
    val ui = _uiState.value
    val what =
        when {
          ui.phase == ReaderPhase.IDLE -> str(R.string.voice_nudge_start)
          ui.lastResult == CaptureResult.HINT -> str(R.string.book_say_cant_see_page)
          else -> str(R.string.voice_nudge_waiting) + " " + waitingHint()
        }
    return if (last) what + " " + str(R.string.voice_nudge_last) else what
  }

  /** Pause for the conditions that stop reading; keep the place when the battery is nearly gone. */
  override fun onHealthAlert(alert: HealthAlert): String? {
    when (alert) {
      HealthAlert.GlassesDisconnected,
      HealthAlert.GlassesRemoved,
      HealthAlert.GlassesTooHot -> if (_uiState.value.isRunning) pause()
      is HealthAlert.GlassesBattery -> if (alert.level == BatteryLevel.CRITICAL) saveBookmark()
      is HealthAlert.PhoneBattery -> if (alert.level == BatteryLevel.CRITICAL) saveBookmark()
      else -> Unit
    }
    return null
  }

  /**
   * A fold or session end: stop talking, keep the bookmark. Paused, not reset: the page already
   * captured can still be read ("read" carries on). ToolHub reconnects and explains.
   */
  override fun onStreamLost(): Boolean {
    if (_uiState.value.phase == ReaderPhase.IDLE) return false
    hush()
    captureJob?.cancel()
    retryJob?.cancel()
    saveBookmark()
    processor.flushCarry()
    _uiState.update {
      it.copy(phase = ReaderPhase.PAUSED, isCapturing = false, status = str(R.string.book_status_stream_lost))
    }
    return true
  }

  /** One transcript, as if from the mic. Public so tests can drive it without audio. */
  fun onUtterance(text: String, isFinal: Boolean) = hub.onUtterance(text, isFinal)

  private fun handle(command: VoiceCommand) {
    val phase = _uiState.value.phase
    when (command) {
      VoiceCommand.Pause -> voicePause()
      VoiceCommand.Resume ->
          when (phase) {
            ReaderPhase.IDLE -> start()
            ReaderPhase.PAUSED -> resume()
            // "Read" while waiting: read what's in front of me now.
            ReaderPhase.WAITING -> if (_uiState.value.isCapturing) reply(waitingHint()) else nextPage()
            ReaderPhase.READING -> Unit
          }
      VoiceCommand.NextPage -> nextPage()
      VoiceCommand.Repeat -> jump { page, at -> sentenceStart(page, at) }
      is VoiceCommand.Back ->
          jump { page, at ->
            var i = at
            repeat(command.sentences) { i = SpeechChunker.previousSentenceStart(page.chunks, i) }
            i
          }
      VoiceCommand.BackParagraph ->
          jump { page, at ->
            val p = page.chunks[at].paragraph
            page.chunks.indexOfFirst { it.paragraph == p }.coerceAtLeast(0)
          }
      VoiceCommand.FromTop -> jump { _, _ -> 0 }
      is VoiceCommand.Faster -> changeRate(_uiState.value.speechRate + command.step)
      is VoiceCommand.Slower -> changeRate(_uiState.value.speechRate - command.step)
      is VoiceCommand.SetRate -> changeRate(command.rate)
      VoiceCommand.WhereAmI -> reply(whereAmI())
      VoiceCommand.Battery -> reply(hub.batteryReport())
      VoiceCommand.Help ->
          reply(
              if (hub.hasHomeMenu) str(R.string.voice_help) + " " + str(R.string.home_help_in_tool)
              else str(R.string.voice_help),
          )
      is VoiceCommand.ReadFurniture -> {
        setReadFurniture(command.enabled)
        reply(str(if (command.enabled) R.string.voice_furniture_on else R.string.voice_furniture_off))
      }
      is VoiceCommand.AutoTurn -> {
        setAutoTurn(command.enabled)
        reply(str(if (command.enabled) R.string.voice_auto_turn_on else R.string.voice_auto_turn_off))
      }
      VoiceCommand.Close -> {
        stop()
        // Back to the main menu (which says so) or out of the app (goodbye): ToolHub decides.
        sayAside(str(if (hub.closeLeavesApp) R.string.voice_goodbye else R.string.voice_bookmark_saved))
        _uiState.update { it.copy(closeRequested = true) }
      }
    }
  }

  private fun voicePause() {
    if (!_uiState.value.isRunning) return
    pause()
    sayAside(str(R.string.voice_paused))
  }

  /** Answer now: cut the sentence being read, speak, then read that sentence again. */
  private fun reply(text: String) = hub.reply(text)

  /**
   * Moves the reading position on the current page (or, between pages, the page just finished) to
   * [target] and reads from there. [target] gets the page and the chunk being read now.
   */
  private fun jump(target: (Page, Int) -> Int) {
    val page = current ?: lastPage
    if (page == null || page.chunks.isEmpty()) {
      reply(str(R.string.voice_nothing_read_yet))
      return
    }
    earcons.play(Earcon.ACK)
    val at =
        if (current == null) page.chunks.lastIndex
        else chunkIndex.coerceAtMost(page.chunks.lastIndex)
    if (current == null) {
      current = page
      // Reading the finished page again: it no longer counts as done.
      _uiState.update { it.copy(pagesRead = (it.pagesRead - 1).coerceAtLeast(0)) }
    }
    chunkIndex = target(page, at).coerceIn(0, page.chunks.lastIndex)
    hush()
    retryJob?.cancel()
    _uiState.update {
      it.copy(
          phase = ReaderPhase.READING,
          pageText = page.displayText,
          chunks = page.chunks.map(SpeechChunk::text),
          status = str(R.string.book_status_reading),
      )
    }
    speakCurrent()
  }

  private fun sentenceStart(page: Page, at: Int): Int {
    val sentence = page.chunks[at].sentence
    return page.chunks.indexOfFirst { it.sentence == sentence }.coerceAtLeast(0)
  }

  private fun changeRate(requested: Float) {
    val before = _uiState.value.speechRate
    setSpeechRate(requested)
    val after = _uiState.value.speechRate
    reply(hub.rateReply(before, requested, after))
  }

  private fun whereAmI(): String {
    val app = getApplication<Application>()
    val rate = formatRate(_uiState.value.speechRate)
    val page = current
    if (page == null || page.chunks.isEmpty()) {
      return app.getString(R.string.voice_where_waiting, _uiState.value.pagesRead, rate)
    }
    val sentences = page.chunks.map { it.sentence }.distinct()
    val now = page.chunks[chunkIndex.coerceAtMost(page.chunks.lastIndex)].sentence
    return app.getString(
        R.string.voice_where_reading,
        _uiState.value.pagesRead + 1,
        sentences.indexOf(now) + 1,
        sentences.size,
        rate,
    )
  }

  private fun waitingHint(): String =
      str(if (_uiState.value.autoTurn) R.string.voice_waiting_auto else R.string.voice_waiting_manual)

  private fun formatRate(rate: Float): String = hub.formatRate(rate)

  /** Stops speech now (ToolHub also tells the echo guard). */
  private fun hush() = hub.hush()

  // MARK: - Session end and errors

  /**
   * Not streaming but the user wants to read: bring the link up (narrated by ToolHub), then run
   * [then]. Without voice open there's no way to ask for permission, so say it can't.
   */
  private fun reconnectThen(then: () -> Unit) {
    if (!hub.reconnectThen(then)) fail(R.string.book_error_not_streaming)
  }

  private fun fail(@StringRes message: Int) {
    earcons.play(Earcon.ERROR)
    val text = str(message)
    _uiState.update { it.copy(lastResult = CaptureResult.FAILED, status = text) }
    if (current == null) sayAside(text)
  }

  private fun saveBookmark(spoken: SpeechChunk? = null) {
    val page = current
    val chunk = spoken ?: page?.chunks?.getOrNull(chunkIndex - 1) ?: return
    val bookmark = Bookmark(_uiState.value.pagesRead, chunk.sentenceText)
    // The recent text goes next to the bookmark, for "what happened last time" after a restart.
    AskMemory.save(prefs.edit().putString(KEY_BOOKMARK, bookmark.encode()), hub.recentText.snapshot(ToolId.BOOK)).apply()
  }

  private fun str(@StringRes id: Int): String = getApplication<Application>().getString(id)

  override fun onCleared() {
    super.onCleared()
    saveBookmark()
    ocr.close()
  }

  class Factory(
      private val application: Application,
      private val hub: ToolHub,
  ) : ViewModelProvider.Factory {
    override fun <T : ViewModel> create(modelClass: Class<T>): T {
      if (modelClass.isAssignableFrom(BookReaderViewModel::class.java)) {
        @Suppress("UNCHECKED_CAST")
        return BookReaderViewModel(application, hub) as T
      }
      throw IllegalArgumentException("Unknown ViewModel class")
    }
  }
}
