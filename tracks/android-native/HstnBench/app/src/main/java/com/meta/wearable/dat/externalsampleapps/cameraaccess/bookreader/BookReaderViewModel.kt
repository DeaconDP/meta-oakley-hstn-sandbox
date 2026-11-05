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
// Voice is the primary control, not an extra: a blind reader can't see the buttons. While the reader
// is open it listens (glasses mic first, phone mic as fallback; VoiceControl), understands on-device
// (book/VoiceCommands), and answers out loud. Replies interrupt the sentence being read and then
// read it again, so the user never waits for a long sentence to finish. EchoGuard drops transcripts
// that are just the book (or our replies) coming back through the mic. Launched straight into the
// reader (voice-first), it also brings the glasses link up by itself and narrates each step.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.bookreader

import android.app.Application
import android.content.Context
import android.os.SystemClock
import android.util.Log
import androidx.annotation.StringRes
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.meta.wearable.dat.externalsampleapps.cameraaccess.R
import com.meta.wearable.dat.externalsampleapps.cameraaccess.bench.BenchClock
import com.meta.wearable.dat.core.Wearables
import com.meta.wearable.dat.core.types.Permission
import com.meta.wearable.dat.core.types.PermissionStatus
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.BatteryLevel
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.Bookmark
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.EchoGuard
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.GlassesSnapshot
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.HealthAlert
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.HealthMonitor
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.IdleNudge
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.ImageCheck
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.ImageIssue
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.PhoneSnapshot
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
import java.util.Locale
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

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
    private val camera: PageCamera,
) : AndroidViewModel(application), BookSpeaker.Listener {

  companion object {
    private const val TAG = "BookReader"
    private const val PREFS = "book_reader"
    private const val KEY_BOOKMARK = "bookmark"
    private const val KEY_RATE = "speech_rate"
    private const val KEY_FURNITURE = "read_furniture"
    private const val KEY_AUTO = "auto_turn"
    private const val MAX_HINTS = 3
    private const val HINT_RETRY_MS = 2500L
    private const val LINK_WAIT_MS = 20_000L
    private const val SORRY_GAP_MS = 8_000L
    private const val SORRY_MAX_WORDS = 6
    private const val TICK_MS = 2_500L
    private const val STILL_WORKING_MS = 10_000L
    private const val STREAM_LOST_SAY_DELAY_MS = 1_500L
    private const val ALERT_EXPLAINS_MS = 4_000L
    private const val RECONNECT_EVERY_MS = 4_000L
    private const val NUDGE_CHECK_MS = 1_000L
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
  private val earcons = Earcons()
  private val speaker = BookSpeaker(application, this).apply { setRate(_uiState.value.speechRate) }
  private val voice = VoiceControl(application, viewModelScope)
  private val echo = EchoGuard()
  private val nudge = IdleNudge()

  // Main thread only.
  private var current: Page? = null
  private var chunkIndex = 0
  private val queue = ArrayDeque<Page>()
  private var captureJob: Job? = null
  private var retryJob: Job? = null
  private var hintAttempts = 0
  private var pendingResume: Bookmark? = null
  private var speakingAside = false
  private var lastPage: Page? = null
  private var voiceJob: Job? = null
  private var lastSorryMs = 0L

  // Pitfalls: glasses/phone health, reconnecting.
  private val watch = ReaderWatch(application)
  private val health = HealthMonitor()
  private var glassesNow: GlassesSnapshot? = null
  private var phoneNow: PhoneSnapshot? = null
  private var requestPermission: (suspend (Permission) -> PermissionStatus)? = null
  private var lastAlertMs = 0L
  private var streamLost = false
  private var reconnectJob: Job? = null
  private var phoneAllowed: (suspend () -> Boolean)? = null
  private var reconnectLoop: Job? = null

  init {
    // Page-turn detection from the stream. Cheap per frame; events hop to main.
    viewModelScope.launch(Dispatchers.Default) {
      camera.frameSizes.collect { frame ->
        val change = motion.onFrame(frame.bytes, frame.isCodecConfig) ?: return@collect
        val event = synchronized(detector) { detector.onFrame(FrameSignal(change)) }
        if (event != null) withContext(Dispatchers.Main) { onTurnEvent(event) }
      }
    }
    // A fold or session end stops the stream: stop talking, keep the bookmark.
    viewModelScope.launch {
      camera.isStreaming.drop(1).collect { streaming ->
        if (!streaming && _uiState.value.phase != ReaderPhase.IDLE) onStreamLost()
        if (streaming && streamLost) onStreamBack()
      }
    }
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
    speakingAside = false
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
      speakingAside = false
      speakCurrent()
    }
  }

  /** A button press or command: acknowledge it, and start silence reminders over. */
  private fun userActed() {
    earcons.play(Earcon.ACK)
    nudge.userActed(SystemClock.elapsedRealtime())
  }

  fun setSpeechRate(rate: Float) {
    val r = (Math.round(rate * 10f) / 10f).coerceIn(MIN_RATE, MAX_RATE)
    speaker.setRate(r)
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
    speakingAside = false
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
    if (!speakingAside) speaker.speak(page.chunks[chunkIndex].text, "chunk")
  }

  private fun publishChunk() {
    _uiState.update { it.copy(currentChunk = chunkIndex) }
  }

  /** Short spoken note (status, hint). Reading resumes after it. */
  private fun sayAside(text: String) {
    speakingAside = true
    speaker.speak(text, "aside")
  }

  override fun onUtteranceStarted(text: String) {
    echo.spoke(text, SystemClock.elapsedRealtime())
  }

  override fun onSpoken(tag: String) {
    echo.finished(SystemClock.elapsedRealtime())
    when (tag) {
      "aside" -> {
        speakingAside = false
        if (_uiState.value.phase == ReaderPhase.READING) speakCurrent()
      }
      "chunk" -> {
        if (_uiState.value.phase != ReaderPhase.READING) return
        val page = current ?: return
        chunkIndex++
        saveBookmark(page.chunks.getOrNull(chunkIndex - 1))
        speakCurrent()
      }
    }
  }

  override fun onEngineState(available: Boolean) {
    _uiState.update { it.copy(speechAvailable = available) }
    // No voice at all: the only thing left to signal with is sound.
    if (!available) earcons.play(Earcon.ERROR)
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

  // MARK: - Voice

  /**
   * Starts listening while the reader screen is open. [voiceFirst]: the app was launched straight
   * into the reader, so bring the glasses link up without dialogs and narrate each step.
   */
  fun openVoice(
      voiceFirst: Boolean,
      requestWearablesPermission: suspend (Permission) -> PermissionStatus,
      requestRecordAudio: suspend () -> Boolean,
  ) {
    if (voiceJob?.isActive == true) return
    _uiState.update { it.copy(closeRequested = false) }
    requestPermission = requestWearablesPermission
    phoneAllowed = requestRecordAudio
    voiceJob = viewModelScope.launch {
      // Everything that can go wrong around the reader is spoken when it changes.
      launch {
        try {
          watch.both().collect { (g, p) ->
            glassesNow = g
            phoneNow = p
            onHealth(health.update(g, p))
          }
        } catch (e: CancellationException) {
          throw e
        } catch (e: Exception) {
          Log.w(TAG, "health watch failed", e)
        }
      }
      // A quiet user gets told what the reader is waiting for.
      launch { remindWhenQuiet() }
      // Permission trouble, whoever started the connection.
      launch {
        camera.link.drop(1).collect { link ->
          when (link) {
            CameraLink.NEEDS_PERMISSION -> sayAside(str(R.string.voice_camera_permission))
            CameraLink.CAMERA_DENIED -> warn(str(R.string.voice_camera_denied))
            else -> Unit
          }
        }
      }
      if (voiceFirst && !camera.isStreaming.value) {
        bringUpLink(requestWearablesPermission)
      } else {
        sayAside(str(R.string.voice_welcome_short))
      }
      // Glasses speech rides the session, so wait (briefly) for one before choosing a mic.
      withTimeoutOrNull(LINK_WAIT_MS) { camera.link.first { it >= CameraLink.CONNECTED } }
      val mic =
          voice.start(
              session = camera.deviceSession,
              glassesAllowed = { glassesMicAllowed(requestWearablesPermission) },
              phoneAllowed = requestRecordAudio,
          )
      Log.i(TAG, "voice microphone=$mic")
      when (mic) {
        Microphone.GLASSES -> Unit
        Microphone.PHONE -> sayAside(str(R.string.voice_using_phone_mic))
        Microphone.NONE -> sayAside(str(R.string.voice_unavailable))
      }
      launch { voice.microphone.collect { m -> _uiState.update { it.copy(microphone = m) } } }
      voice.utterances.collect { onUtterance(it.text, it.isFinal) }
    }
  }

  /** Stops listening (screen closed). The bookmark and reading state are kept. */
  fun closeVoice() {
    voiceJob?.cancel()
    voiceJob = null
    reconnectJob?.cancel()
    reconnectLoop?.cancel()
    requestPermission = null
    phoneAllowed = null
    voice.stop()
    _uiState.update { it.copy(microphone = Microphone.NONE) }
  }

  /**
   * Runs while voice is on. When the reader is waiting for the user (not started, or between pages)
   * and nobody has said anything for a while, say what it's waiting for. IdleNudge spaces the
   * reminders out and stops after the last one, until the user does something.
   */
  private suspend fun remindWhenQuiet() {
    nudge.userActed(SystemClock.elapsedRealtime())
    while (true) {
      delay(NUDGE_CHECK_MS)
      val now = SystemClock.elapsedRealtime()
      if (!waitingForUser()) {
        nudge.busy(now)
        continue
      }
      val reminder = nudge.due(now) ?: continue
      val ui = _uiState.value
      val app = getApplication<Application>()
      val what =
          when {
            ui.phase == ReaderPhase.IDLE -> str(R.string.voice_nudge_start)
            ui.lastResult == CaptureResult.HINT -> str(R.string.book_say_cant_see_page)
            else -> str(R.string.voice_nudge_waiting) + " " + waitingHint()
          }
      val text = if (nudge.isLast(reminder)) what + " " + app.getString(R.string.voice_nudge_last) else what
      Log.i(TAG, "nudge reminder=$reminder text=$text")
      sayAside(text)
    }
  }

  /** Nothing to read, nothing in progress, glasses there: only the user can move things on. */
  private fun waitingForUser(): Boolean {
    val ui = _uiState.value
    return (ui.phase == ReaderPhase.IDLE || ui.phase == ReaderPhase.WAITING) &&
        !ui.closeRequested &&
        !ui.isCapturing &&
        !speakingAside &&
        current == null &&
        queue.isEmpty() &&
        captureJob?.isActive != true &&
        retryJob?.isActive != true &&
        reconnectJob?.isActive != true &&
        !streamLost &&
        camera.isStreaming.value
  }

  private suspend fun bringUpLink(requestPermission: suspend (Permission) -> PermissionStatus) {
    val narration = viewModelScope.launch {
      camera.link.collect { link ->
        if (link == CameraLink.CONNECTING) sayAside(str(R.string.voice_connecting))
      }
    }
    camera.connectAndStream(requestPermission)
    val up = withTimeoutOrNull(LINK_WAIT_MS) { camera.isStreaming.first { it } }
    narration.cancel()
    if (up == true) {
      earcons.play(Earcon.PAGE_DONE)
      sayAside(str(R.string.voice_welcome_ready))
    } else {
      explainNoGlasses()
      // Keep waiting quietly; welcome the user when the glasses turn up.
      viewModelScope.launch {
        camera.isStreaming.first { it }
        sayAside(str(R.string.voice_welcome_ready))
      }
    }
  }

  private suspend fun glassesMicAllowed(
      requestPermission: suspend (Permission) -> PermissionStatus,
  ): Boolean {
    val granted =
        Wearables.checkPermissionStatus(Permission.MICROPHONE).fold(
            onSuccess = { it == PermissionStatus.Granted },
            onFailure = { error, _ ->
              Log.w(TAG, "microphone permission check failed: ${error.description}")
              false
            },
        )
    if (granted) return true
    sayAside(str(R.string.voice_mic_permission))
    return requestPermission(Permission.MICROPHONE) == PermissionStatus.Granted
  }

  /** One transcript from the mic. Public so tests can drive it without audio. */
  fun onUtterance(text: String, isFinal: Boolean) {
    val now = SystemClock.elapsedRealtime()
    if (echo.isEcho(text, now)) {
      if (isFinal) Log.i(TAG, "voice echo ignored: \"$text\"")
      return
    }
    if (!isFinal) {
      // Barge-in: stop talking on the partial, don't wait for the recogniser to finish.
      if (_uiState.value.phase == ReaderPhase.READING && VoiceCommands.isBargeIn(text)) {
        Log.i(TAG, "voice barge-in on partial: \"$text\"")
        voicePause()
      }
      return
    }
    _uiState.update { it.copy(heard = text) }
    // Even speech that isn't a command means the user is there: no reminder needed yet.
    nudge.userActed(now)
    val command = VoiceCommands.parse(text)
    Log.i(TAG, "voice heard=\"$text\" command=$command")
    if (command == null) {
      notUnderstood(text, now)
      return
    }
    handle(command)
  }

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
      VoiceCommand.Battery -> reply(batteryReport())
      VoiceCommand.Help -> reply(str(R.string.voice_help))
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
        sayAside(str(R.string.voice_goodbye))
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
  private fun reply(text: String) {
    earcons.play(Earcon.ACK)
    hush()
    speakingAside = false
    sayAside(text)
  }

  private fun notUnderstood(text: String, now: Long) {
    // While a page is being read, unknown speech is most likely the room, not the user.
    if (_uiState.value.phase == ReaderPhase.READING) return
    if (text.trim().split(Regex("\\s+")).size > SORRY_MAX_WORDS) return
    if (now - lastSorryMs < SORRY_GAP_MS) return
    lastSorryMs = now
    reply(str(R.string.voice_not_understood))
  }

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
    speakingAside = false
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
    val text =
        when {
          after == before && requested > before -> str(R.string.voice_rate_fastest)
          after == before && requested < before -> str(R.string.voice_rate_slowest)
          else -> getApplication<Application>().getString(R.string.voice_rate, formatRate(after))
        }
    reply(text)
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

  private fun formatRate(rate: Float): String =
      if (rate % 1f == 0f) rate.toInt().toString()
      else String.format(Locale.US, "%.2f", rate).trimEnd('0')

  /** Stops speech now and tells the echo guard it ended. */
  private fun hush() {
    speaker.stop()
    echo.finished(SystemClock.elapsedRealtime())
  }

  // MARK: - Session end and errors

  private fun onStreamLost() {
    hush()
    speakingAside = false
    captureJob?.cancel()
    retryJob?.cancel()
    saveBookmark()
    earcons.play(Earcon.ERROR)
    streamLost = true
    processor.flushCarry()
    // Paused, not reset: the page already captured can still be read ("read" carries on), and the
    // place is kept for when the glasses come back.
    _uiState.update {
      it.copy(phase = ReaderPhase.PAUSED, isCapturing = false, status = str(R.string.book_status_stream_lost))
    }
    val pausedByGlasses = camera.link.value == CameraLink.PAUSED
    if (!pausedByGlasses) keepTryingToReconnect()
    viewModelScope.launch {
      // A health alert ("glasses disconnected", "taken off") usually explains it better; give it
      // a moment to arrive and only speak the generic line if nothing did.
      delay(STREAM_LOST_SAY_DELAY_MS)
      if (camera.isStreaming.value) return@launch
      val now = SystemClock.elapsedRealtime()
      when {
        pausedByGlasses -> sayAside(str(R.string.book_say_paused_by_glasses))
        now - lastAlertMs > ALERT_EXPLAINS_MS -> sayAside(str(R.string.book_status_stream_lost))
      }
    }
  }

  /**
   * Folding (or a session ending) doesn't always show up as a link change, so while the stream
   * is lost and the reader is open, quietly try to bring it back whenever the glasses look
   * reachable. Stops once streaming again or the reader closes.
   */
  private fun keepTryingToReconnect() {
    if (reconnectLoop?.isActive == true) return
    reconnectLoop = viewModelScope.launch {
      while (streamLost && voiceJob?.isActive == true) {
        delay(RECONNECT_EVERY_MS)
        if (camera.isStreaming.value) break
        val g = glassesNow
        // Not gated on "worn": after a fold the glasses can keep reporting "off" until used.
        val reachable = g == null || g.connected
        val busy = camera.link.value.let {
          it == CameraLink.CONNECTING || it == CameraLink.STARTING_STREAM ||
              it == CameraLink.NEEDS_PERMISSION || it == CameraLink.CAMERA_DENIED
        }
        if (reachable && !busy) requestPermission?.let { camera.connectAndStream(it) }
      }
    }
  }

  /** The stream came back after a loss: say so, and move voice back onto the glasses. */
  private fun onStreamBack() {
    streamLost = false
    if (voiceJob?.isActive != true) return
    earcons.play(Earcon.PAGE_DONE)
    say(str(R.string.book_say_glasses_back))
    restartVoiceOnGlasses()
  }

  /**
   * Not streaming but the user wants to read: bring the link up (narrated), then run [then]. If
   * it doesn't come up, say why it can't.
   */
  private fun reconnectThen(then: () -> Unit) {
    val rp = requestPermission
    if (rp == null) {
      fail(R.string.book_error_not_streaming)
      return
    }
    if (reconnectJob?.isActive == true) return
    sayAside(str(R.string.voice_connecting))
    camera.connectAndStream(rp)
    reconnectJob = viewModelScope.launch {
      val up = withTimeoutOrNull(LINK_WAIT_MS) { camera.isStreaming.first { it } }
      if (up == true) then() else explainNoGlasses()
    }
  }

  /** The most specific reason the glasses can't be reached, spoken. */
  private fun explainNoGlasses() {
    earcons.play(Earcon.ERROR)
    val g = glassesNow
    val p = phoneNow
    sayAside(
        str(
            when {
              p?.bluetoothOn == false -> R.string.health_bluetooth_off
              g?.paired == false -> R.string.health_no_glasses
              g?.updateRequired == true -> R.string.health_update_required
              camera.link.value == CameraLink.CAMERA_DENIED -> R.string.voice_camera_denied
              g?.connected == true && g.worn == false -> R.string.health_removed
              else -> R.string.voice_no_glasses
            },
        ),
    )
  }

  private fun restartVoiceOnGlasses() {
    val rp = requestPermission ?: return
    viewModelScope.launch {
      voice.stop()
      voice.start(
          session = camera.deviceSession,
          glassesAllowed = { glassesMicAllowed(rp) },
          phoneAllowed = phoneAllowed ?: { false },
      )
    }
  }

  // MARK: - Glasses and phone health

  private fun onHealth(alerts: List<HealthAlert>) {
    for (alert in alerts) {
      Log.i(TAG, "health=$alert")
      lastAlertMs = SystemClock.elapsedRealtime()
      val app = getApplication<Application>()
      when (alert) {
        HealthAlert.BluetoothOff -> warn(str(R.string.health_bluetooth_off))
        HealthAlert.BluetoothOn -> say(str(R.string.health_bluetooth_on))
        HealthAlert.NoGlassesPaired -> warn(str(R.string.health_no_glasses))
        HealthAlert.GlassesDisconnected -> {
          if (_uiState.value.isRunning) pause()
          warn(str(R.string.health_disconnected))
        }
        HealthAlert.GlassesConnected -> {
          say(str(R.string.health_connected))
          // Bring the camera back by itself; onStreamBack says when it's ready.
          if (!camera.isStreaming.value) requestPermission?.let { camera.connectAndStream(it) }
        }
        HealthAlert.GlassesRemoved -> {
          if (_uiState.value.isRunning) pause()
          warn(str(R.string.health_removed))
        }
        HealthAlert.GlassesWornAgain -> say(str(R.string.health_worn_again))
        HealthAlert.UpdateRequired -> warn(str(R.string.health_update_required))
        is HealthAlert.GlassesBattery -> {
          if (alert.level == BatteryLevel.CRITICAL) saveBookmark()
          warn(
              app.getString(
                  if (alert.level == BatteryLevel.CRITICAL) R.string.health_glasses_battery_critical
                  else R.string.health_glasses_battery_low,
                  alert.percent,
              ),
          )
        }
        is HealthAlert.PhoneBattery -> {
          if (alert.level == BatteryLevel.CRITICAL) saveBookmark()
          warn(app.getString(R.string.health_phone_battery_low, alert.percent))
        }
        HealthAlert.GlassesHot -> warn(str(R.string.health_hot))
        HealthAlert.GlassesTooHot -> {
          if (_uiState.value.isRunning) pause()
          warn(str(R.string.health_too_hot))
        }
        HealthAlert.GlassesCooled -> say(str(R.string.health_cooled))
      }
    }
  }

  /** A problem: error earcon, then interrupt and say it. Reading carries on after if it can. */
  private fun warn(text: String) {
    earcons.play(Earcon.ERROR)
    _uiState.update { it.copy(status = text) }
    reply(text)
  }

  private fun say(text: String) {
    _uiState.update { it.copy(status = text) }
    sayAside(text)
  }

  private fun batteryReport(): String {
    val app = getApplication<Application>()
    val g = glassesNow?.takeIf { it.connected }?.battery
    val p = phoneNow?.battery
    return when {
      g != null && p != null -> app.getString(R.string.voice_battery_both, g, p)
      g != null -> app.getString(R.string.voice_battery_glasses, g)
      p != null -> app.getString(R.string.voice_battery_phone, p)
      else -> str(R.string.voice_battery_unknown)
    }
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
    prefs.edit().putString(KEY_BOOKMARK, bookmark.encode()).apply()
  }

  private fun str(@StringRes id: Int): String = getApplication<Application>().getString(id)

  override fun onCleared() {
    super.onCleared()
    voice.stop()
    saveBookmark()
    speaker.shutdown()
    earcons.release()
    ocr.close()
  }

  class Factory(
      private val application: Application,
      private val camera: PageCamera,
  ) : ViewModelProvider.Factory {
    override fun <T : ViewModel> create(modelClass: Class<T>): T {
      if (modelClass.isAssignableFrom(BookReaderViewModel::class.java)) {
        @Suppress("UNCHECKED_CAST")
        return BookReaderViewModel(application, camera) as T
      }
      throw IllegalArgumentException("Unknown ViewModel class")
    }
  }
}
