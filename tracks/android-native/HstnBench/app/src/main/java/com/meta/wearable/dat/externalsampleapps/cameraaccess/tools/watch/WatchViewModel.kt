// WatchViewModel - Watch for text: keep reading the glasses' view and say when the target appears
//
// "Tell me when you see 42", "watch for exit", "find Boots". Once it has a target (from the voice
// phrase, the deep link / intent argument, or by asking "What should I watch for?"), it reads stream
// frames at up to 2 a second (hub.camera.frames), checks each for a covered lens or darkness
// (book/ImageCheck), runs ML Kit on the rest (bookreader/MlKitOcr), and looks for the target
// (TextMatcher: loose for words, exact for numbers). SightingTracker decides what to say: an earcon
// and "42, on your right" when it's been seen in two of the last four frames, "42, gone" a few
// seconds after it leaves the view, again when it comes back, and now and then "I see 24, not 42".
// A soft tick every 10 s (user-tunable, or off) says it's still watching; problems are always
// spoken: lens covered, too dark, no pictures, OCR failing or too slow. Glasses off, disconnected
// and stream lost come from ToolHub's pitfalls. It's orientation help only, and says so once when
// watching starts. Commands: WatchGrammar; pause/carry on/close/help go through the global grammar.
// The screen mirrors all of it (WatchTool).

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.watch

import android.app.Application
import android.content.Context
import android.graphics.Bitmap
import android.os.SystemClock
import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.meta.wearable.dat.externalsampleapps.cameraaccess.R
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.ImageCheck
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.ImageIssue
import com.meta.wearable.dat.externalsampleapps.cameraaccess.bookreader.MlKitOcr
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.Earcon
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.OpenReason
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolHub
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolTexts
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolViewModel
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.GlobalCommand
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.GlobalGrammar
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.Phrases
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolRequest
import java.util.Locale
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

enum class WatchPhase {
  /** No target yet: asked "What should I watch for?". */
  ASKING,
  /** Reading frames and looking for the target. */
  WATCHING,
  /** Stopped or paused; the target is kept for "carry on watching". */
  STOPPED,
}

/** What the watch screen shows beyond the common tool state. */
data class WatchUi(
    val phase: WatchPhase = WatchPhase.ASKING,
    val target: String? = null,
    /** The last sighting as spoken ("42, on your right."), or null. */
    val lastSighting: String? = null,
    val tickSeconds: Int = WatchViewModel.DEFAULT_TICK_S,
    /** Average OCR time per frame, ms. */
    val ocrMs: Int? = null,
    /** Frames read per second. */
    val fps: Float? = null,
    /** What OCR read in the last frame, lines joined with " / " (shown for helpers; tests use it). */
    val lastRead: String? = null,
)

class WatchViewModel(application: Application, hub: ToolHub) :
    ToolViewModel(application, hub, ToolId.WATCH) {

  companion object {
    private const val TAG = "WatchForText"
    const val FPS = 2f
    const val DEFAULT_TICK_S = 10
    /** Tick choices the screen button cycles through (0 = off). */
    val TICK_CHOICES = listOf(10, 20, 30, 0)
    private const val PREFS = "tools"
    private const val KEY_TICK = "watch_tick_seconds"
    /** No processed frame for this long while streaming: say so. */
    private const val NO_FRAMES_MS = 10_000L
    /** Ticks only while frames are arriving. */
    private const val FRAME_FRESH_MS = 5_000L
    private const val OCR_FAILS_BEFORE_WARNING = 3
    private const val MAX_ANSWER_WORDS = 4
  }

  private val prefs = application.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

  private val _watch = MutableStateFlow(WatchUi(tickSeconds = prefs.getInt(KEY_TICK, DEFAULT_TICK_S)))
  val watch: StateFlow<WatchUi> = _watch.asStateFlow()

  private var target: WatchTarget? = null
  private var loop: Job? = null
  private var ticker: Job? = null
  private var ocr: MlKitOcr? = null
  private val tracker = SightingTracker()
  private val viewIssues = ViewIssueWatch()
  private val pace = PaceWatch()
  private var saidNotAMobilityAid = false
  private var lastFrameMs = 0L
  private var lastTickMs = 0L
  private var watchStartMs = 0L
  private var noFramesSaid = false
  private var ocrFails = 0
  private var ocrFailSaid = false
  private val ocrTimes = ArrayDeque<Long>()
  private var framesDone = 0
  private var firstFrameMs = 0L

  override fun texts(): ToolTexts =
      ToolTexts.generic(getApplication(), R.string.watch_name, R.string.watch_help)

  override fun onOpened(request: ToolRequest, reason: OpenReason) {
    val arg = request.argument
    when {
      arg != null -> startWatching(arg, announceAsNew = true)
      // Back to the tool by voice or a tap with no new target: carry on with the old one.
      target != null -> resume()
      else -> ask()
    }
  }

  /** "watch for 73" while open (from the global grammar, or a deep link to the open tool). */
  override fun onRequest(request: ToolRequest) {
    super.onRequest(request)
    val arg = request.argument
    if (arg != null) startWatching(arg, announceAsNew = true) else if (target == null) ask() else whatTarget()
  }

  override fun onLeaving() {
    stopLoop()
    if (target != null) _watch.update { it.copy(phase = WatchPhase.STOPPED) }
  }

  override fun onCleared() {
    stopLoop()
    ocr?.close()
    ocr = null
    super.onCleared()
  }

  // MARK: voice

  override fun onCommand(text: String): Boolean {
    val normalized = Phrases.normalize(text)
    val light = Phrases.light(text)
    val command = WatchGrammar.parse(normalized, light)
    if (command != null) {
      handle(command)
      return true
    }
    if (_watch.value.phase == WatchPhase.ASKING) {
      // The answer to "What should I watch for?". Leave real commands ("close", "help") to the
      // global grammar, except "exit", which is a sign people watch for.
      val global = GlobalGrammar.parse(text)
      if (global != null && !(global == GlobalCommand.Close && normalized in setOf("exit", "way out"))) return false
      // A target is short ("42", "platform 3", "the way out"); longer speech is probably the room.
      if (normalized.isEmpty() || Phrases.wordCount(normalized) > MAX_ANSWER_WORDS) return false
      startWatching(light, announceAsNew = true)
      return true
    }
    return false
  }

  override fun onGlobal(command: GlobalCommand): Boolean =
      when (command) {
        GlobalCommand.Pause -> {
          val t = target
          if (t != null && _watch.value.phase == WatchPhase.WATCHING) {
            hub.hush()
            stopLoop()
            _watch.update { it.copy(phase = WatchPhase.STOPPED) }
            say(str(R.string.watch_paused, t.display))
            true
          } else {
            false
          }
        }
        GlobalCommand.Resume ->
            when {
              _watch.value.phase == WatchPhase.WATCHING -> false
              target != null -> {
                hub.userActed()
                resume()
                true
              }
              else -> {
                ask()
                true
              }
            }
        else -> false
      }

  /** Room chatter while watching is expected (a bus stop): don't say "sorry". */
  override fun isBusy(): Boolean = _watch.value.phase == WatchPhase.WATCHING

  override fun isWaitingForUser(): Boolean = _watch.value.phase != WatchPhase.WATCHING

  override fun reminder(index: Int, last: Boolean): String? {
    val t = target
    return if (_watch.value.phase == WatchPhase.ASKING || t == null) str(R.string.watch_reminder_ask)
    else str(R.string.watch_reminder_stopped, t.display)
  }

  override fun onStreamBack() {
    // Whatever was in view before the gap may not be now; start the sighting count afresh.
    tracker.reset()
    viewIssues.reset()
    pace.reset()
  }

  private fun handle(command: WatchCommand) {
    when (command) {
      WatchCommand.Stop -> {
        val t = target
        if (t == null) {
          hub.reply(str(R.string.watch_not_watching))
        } else {
          stopLoop()
          _watch.update { it.copy(phase = WatchPhase.STOPPED) }
          hub.reply(str(R.string.watch_stopped, t.display))
        }
      }
      WatchCommand.Resume -> {
        if (target == null) ask()
        else if (_watch.value.phase == WatchPhase.WATCHING) whatTarget()
        else {
          hub.userActed()
          resume()
        }
      }
      WatchCommand.WhatTarget -> whatTarget()
      WatchCommand.Where -> where()
      is WatchCommand.NewTarget -> command.target?.let { startWatching(it, announceAsNew = true) } ?: ask()
      is WatchCommand.Ticks -> setTicks(command.seconds ?: DEFAULT_TICK_S, spoken = true)
    }
  }

  // MARK: buttons (the screen calls these)

  fun whereButton() {
    hub.userActed()
    where()
  }

  fun toggleButton() {
    hub.userActed()
    when {
      _watch.value.phase == WatchPhase.WATCHING -> handle(WatchCommand.Stop)
      target != null -> resume()
      else -> ask()
    }
  }

  fun changeButton() {
    hub.userActed()
    ask()
  }

  fun cycleTicksButton() {
    hub.userActed()
    val i = TICK_CHOICES.indexOf(_watch.value.tickSeconds)
    setTicks(TICK_CHOICES[(i + 1) % TICK_CHOICES.size], spoken = true)
  }

  // MARK: what it says

  private fun ask() {
    stopLoop()
    target = null
    _watch.update { it.copy(phase = WatchPhase.ASKING, target = null, lastSighting = null) }
    say(str(R.string.watch_ask_target))
  }

  private fun whatTarget() {
    val t = target
    hub.reply(
        when {
          t == null -> str(R.string.watch_not_watching)
          _watch.value.phase == WatchPhase.WATCHING -> str(R.string.watch_what_target, t.display)
          else -> str(R.string.watch_what_target_stopped, t.display)
        },
    )
  }

  private fun where() {
    val t = target
    if (t == null) {
      hub.reply(str(R.string.watch_where_nothing))
      return
    }
    val now = SystemClock.elapsedRealtime()
    hub.reply(
        when (val a = tracker.where(now)) {
          is WhereAnswer.InView -> str(R.string.watch_where_in_view, t.display, placeOf(a.spot))
          is WhereAnswer.LastSeen ->
              str(R.string.watch_where_last_seen, t.display, placeOf(a.spot), (a.agoMs / 1000).toInt())
          WhereAnswer.NotSeen -> str(R.string.watch_where_not_seen, t.display)
        },
    )
  }

  /** "on your right", "ahead, close". */
  private fun placeOf(spot: Spot): String {
    val side =
        str(
            when (Position.side(spot.x)) {
              Side.LEFT -> R.string.watch_left
              Side.AHEAD -> R.string.watch_ahead
              Side.RIGHT -> R.string.watch_right
            },
        )
    return when (Position.nearness(spot.heightFraction)) {
      Nearness.CLOSE -> str(R.string.watch_where_close, side)
      Nearness.FAR -> str(R.string.watch_where_far, side)
      null -> side
    }
  }

  private fun setTicks(seconds: Int, spoken: Boolean) {
    prefs.edit().putInt(KEY_TICK, seconds).apply()
    _watch.update { it.copy(tickSeconds = seconds) }
    if (spoken) hub.reply(if (seconds == 0) str(R.string.watch_ticks_off) else str(R.string.watch_ticks_every, seconds))
  }

  // MARK: watching

  private fun startWatching(raw: String, announceAsNew: Boolean) {
    val t = WatchTarget.parse(raw)
    if (t == null) {
      hub.warn(str(R.string.watch_didnt_get_target))
      _watch.update { it.copy(phase = WatchPhase.ASKING) }
      return
    }
    target = t
    tracker.reset()
    _watch.update { it.copy(target = t.display, lastSighting = null) }
    Log.i(TAG, "watch target=\"${t.display}\" tokens=${t.tokens}")
    val line =
        if (!saidNotAMobilityAid) {
          saidNotAMobilityAid = true
          str(R.string.watch_start_first, t.display)
        } else {
          str(R.string.watch_start, t.display)
        }
    if (announceAsNew) say(line)
    startLoop()
  }

  private fun resume() {
    val t = target ?: return ask()
    tracker.reset()
    say(str(R.string.watch_resumed, t.display))
    startLoop()
  }

  private fun stopLoop() {
    loop?.cancel()
    loop = null
    ticker?.cancel()
    ticker = null
  }

  private fun startLoop() {
    stopLoop()
    viewIssues.reset()
    pace.reset()
    ocrTimes.clear()
    framesDone = 0
    noFramesSaid = false
    ocrFails = 0
    ocrFailSaid = false
    watchStartMs = SystemClock.elapsedRealtime()
    lastFrameMs = 0L
    lastTickMs = watchStartMs
    _watch.update { it.copy(phase = WatchPhase.WATCHING) }
    val engine = ocr ?: MlKitOcr().also { ocr = it }
    loop = viewModelScope.launch {
      // conflate: if OCR is slower than the frame rate, skip to the newest frame.
      hub.camera.frames(FPS).conflate().collect { bitmap ->
        try {
          processFrame(engine, bitmap)
        } finally {
          bitmap.recycle()
        }
      }
    }
    ticker = viewModelScope.launch { tickAndWatchdog() }
  }

  private suspend fun processFrame(engine: MlKitOcr, bitmap: Bitmap) {
    val t = target ?: return
    val now = SystemClock.elapsedRealtime()
    lastFrameMs = now
    noFramesSaid = false
    if (firstFrameMs == 0L || framesDone == 0) firstFrameMs = now

    val issue = withContext(Dispatchers.Default) { viewIssue(bitmap) }
    viewIssues.onFrame(now, issue)?.let { e ->
      when (e) {
        is ViewIssueEvent.Started -> hub.warn(issueText(e.issue))
        is ViewIssueEvent.StillThere -> hub.warn(issueText(e.issue))
        ViewIssueEvent.Cleared -> say(str(R.string.watch_view_back, t.display))
      }
    }
    if (issue != null) return

    val started = SystemClock.elapsedRealtime()
    val page =
        try {
          engine.recognize(bitmap)
        } catch (e: CancellationException) {
          throw e
        } catch (e: Exception) {
          Log.w(TAG, "OCR failed", e)
          ocrFails++
          if (ocrFails >= OCR_FAILS_BEFORE_WARNING && !ocrFailSaid) {
            ocrFailSaid = true
            hub.warn(str(R.string.watch_ocr_failed))
          }
          return
        }
    ocrFails = 0
    val ocrMs = SystemClock.elapsedRealtime() - started
    val match = withContext(Dispatchers.Default) { TextMatcher.find(t, page) }
    Log.i(
        TAG,
        "metric=watch_ocr ms=$ocrMs size=${bitmap.width}x${bitmap.height} lines=${page.lines.size} " +
            "hit=${match.hit?.let { "${it.text}@%.2f,h%.3f".format(Locale.US, it.x, it.heightFraction) }} near=${match.nearMiss}",
    )
    noteStats(ocrMs, SystemClock.elapsedRealtime())
    _watch.update { it.copy(lastRead = page.lines.joinToString(" / ") { l -> l.text }.take(160)) }
    if (target !== t) return

    for (event in tracker.onFrame(SystemClock.elapsedRealtime(), match)) {
      when (event) {
        is WatchEvent.Appeared -> {
          hub.earcons.play(Earcon.FOUND)
          val line = str(R.string.watch_seen, t.display, placeOf(event.spot))
          hub.hush()
          say(line)
          _watch.update { it.copy(lastSighting = line) }
        }
        WatchEvent.Gone -> say(str(R.string.watch_gone, t.display))
        is WatchEvent.NearMiss -> {
          if (!hub.isSpeakingAside) say(str(R.string.watch_near_miss, event.seen, t.display))
        }
      }
    }
    pace.onFrameDone(SystemClock.elapsedRealtime())?.let { seconds -> say(str(R.string.watch_slow, seconds)) }
  }

  private fun noteStats(ocrMs: Long, now: Long) {
    ocrTimes.addLast(ocrMs)
    while (ocrTimes.size > 10) ocrTimes.removeFirst()
    framesDone++
    val elapsed = (now - firstFrameMs).coerceAtLeast(1)
    val fps = if (framesDone >= 2) (framesDone - 1) * 1000f / elapsed else null
    _watch.update { it.copy(ocrMs = ocrTimes.average().toInt(), fps = fps) }
  }

  /** Soft tick while watching and frames are arriving; spoken if pictures stop. */
  private suspend fun tickAndWatchdog() {
    while (true) {
      delay(1_000L)
      val now = SystemClock.elapsedRealtime()
      val streaming = hub.camera.isStreaming.value
      val tick = _watch.value.tickSeconds
      val fresh = lastFrameMs != 0L && now - lastFrameMs < FRAME_FRESH_MS
      if (tick > 0 && fresh && viewIssues.current == null && !hub.isSpeakingAside && now - lastTickMs >= tick * 1000L) {
        lastTickMs = now
        hub.earcons.play(Earcon.WORKING)
      }
      // Streaming but nothing arrives (the stream-lost and glasses-off cases are ToolHub's).
      val since = if (lastFrameMs == 0L) now - watchStartMs else now - lastFrameMs
      if (streaming && !hub.streamLost && since > NO_FRAMES_MS && !noFramesSaid) {
        noFramesSaid = true
        hub.warn(str(R.string.watch_no_frames))
      }
    }
  }

  private fun issueText(issue: ViewIssue): String =
      str(if (issue == ViewIssue.COVERED) R.string.watch_covered else R.string.watch_dark)

  /** Lens covered or too dark, from a coarse grid of brightness samples (book/ImageCheck). */
  private fun viewIssue(bitmap: Bitmap): ViewIssue? {
    val src = if (bitmap.config == Bitmap.Config.HARDWARE) bitmap.copy(Bitmap.Config.ARGB_8888, false) ?: return null else bitmap
    val gw = 48
    val gh = 72
    val luma = IntArray(gw * gh)
    for (y in 0 until gh) for (x in 0 until gw) {
      val c = src.getPixel(x * src.width / gw + src.width / (2 * gw), y * src.height / gh + src.height / (2 * gh))
      luma[y * gw + x] = (0.299 * ((c shr 16) and 0xff) + 0.587 * ((c shr 8) and 0xff) + 0.114 * (c and 0xff)).toInt()
    }
    // Only what stops reading signs matters here: a street isn't a page, so "nothing in view",
    // glare and "partly blocked" are normal.
    return when (ImageCheck.check(luma, gw, gh)) {
      ImageIssue.COVERED -> ViewIssue.COVERED
      ImageIssue.TOO_DARK -> ViewIssue.TOO_DARK
      else -> null
    }
  }

  class Factory(private val application: Application, private val hub: ToolHub) :
      ViewModelProvider.Factory {
    override fun <T : ViewModel> create(modelClass: Class<T>): T {
      @Suppress("UNCHECKED_CAST")
      return WatchViewModel(application, hub) as T
    }
  }
}
