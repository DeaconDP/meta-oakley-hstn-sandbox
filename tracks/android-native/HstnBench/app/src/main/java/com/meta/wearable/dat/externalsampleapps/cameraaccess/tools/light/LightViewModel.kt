// LightViewModel - the light and colour tool: a brightness tone, and "what colour is this?"
//
// Two modes, both entirely on the phone:
//  - Light probe (default; "light detector", "is the light on"): reads stream frames at [probeFps],
//    measures centre-weighted brightness (LightMeter), and plays a continuous tone (ProbeTone) whose
//    pitch rises with it (PitchMap, smoothed by PitchSmoother), so turning the head finds a window
//    or tells whether a lamp is on. FlickerDetector watches for a blinking light and says "It's
//    blinking" once when it starts. "How bright is it" speaks a level, saying it's a camera
//    estimate (auto-exposure; DAT exposes no exposure data). "Quiet"/"pause"/"tone off" stop the
//    tone; "carry on"/"tone on" restart it. The tone also stops at once when the tool closes, the
//    user switches tools, the stream drops, the glasses come off or no frames arrive for 2 s, and
//    comes back by itself after a drop if the user hadn't paused it.
//  - Colour ("what colour is this", "colour mode", hstnbench://light?mode=colour): takes the latest
//    frame and names the colour in the centre (ColourReader, ColourSpeech), hedged when the light
//    is dim or tinted. "Again" measures again.
// [state] mirrors everything for the screen and for tests (they can't hear the tone, so the
// current tone frequency is on it). See notes/light-and-colour.md.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.light

import android.app.Application
import android.graphics.Bitmap
import android.os.SystemClock
import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.meta.wearable.dat.externalsampleapps.cameraaccess.R
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.OpenReason
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolHub
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolTexts
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolViewModel
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.GlobalCommand
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.HealthAlert
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.Phrases
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolRequest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

enum class LightMode { PROBE, COLOUR }

/** What the light tool's screen shows (and tests read). */
data class LightState(
    val mode: LightMode = LightMode.PROBE,
    /** The probe loop is running (it may still be silent until the first frame). */
    val probing: Boolean = false,
    /** The user paused the tone ("quiet"); it stays off until "carry on". */
    val paused: Boolean = false,
    /** Frequency of the tone playing now, or 0 when silent. */
    val toneHz: Float = 0f,
    val level: LightLevel? = null,
    val blinking: Boolean = false,
    /** The last colour answer, as spoken. */
    val colourText: String = "",
    val colour: ColourResult? = null,
    /** Swatch to show (ARGB). */
    val swatch: Int? = null,
    /** Average time to analyse one probe frame, ms (on Dispatchers.Default). */
    val probeFrameMs: Float = 0f,
    val probeFrames: Int = 0,
)

class LightViewModel(application: Application, hub: ToolHub) :
    ToolViewModel(application, hub, ToolId.LIGHT) {

  private val _state = MutableStateFlow(LightState())
  val state: StateFlow<LightState> = _state.asStateFlow()

  /** Probe frame rate. 4 a second: see notes/light-and-colour.md > CPU cost. Tests may change it. */
  @Volatile var probeFps: Float = DEFAULT_PROBE_FPS

  private val tone = ProbeTone()
  private val toneLock = Any()
  private var probeJob: Job? = null
  private var colourJob: Job? = null
  private val smoother = PitchSmoother()
  private val flicker = FlickerDetector()
  @Volatile private var lastReading: LightReading? = null
  @Volatile private var lastReadingAt = 0L
  @Volatile private var lastFrameAt = 0L
  private var lastBlinkSaidAt = 0L
  private var attached = false

  override fun texts(): ToolTexts =
      ToolTexts.generic(getApplication(), R.string.light_name, R.string.light_help)

  override fun onAttached(request: ToolRequest) {
    super.onAttached(request)
    attached = true
  }

  override fun onOpened(request: ToolRequest, reason: OpenReason) {
    if (request.mode == ToolRequest.MODE_COLOUR) toColour(announce = true, first = true)
    else toLight(announce = str(R.string.light_probe_on))
  }

  override fun onRequest(request: ToolRequest) {
    super.onRequest(request)
    if (request.mode == ToolRequest.MODE_COLOUR) toColour(announce = _state.value.mode != LightMode.COLOUR, first = false)
    else if (_state.value.mode == LightMode.PROBE && _state.value.probing) howBright()
    else toLight(announce = str(R.string.light_probe_on))
  }

  override fun onLeaving() {
    attached = false
    stopProbe()
    colourJob?.cancel()
  }

  override fun onDetached() {
    attached = false
    stopProbe()
    colourJob?.cancel()
  }

  override fun onCleared() {
    stopProbe()
    tone.stop()
    super.onCleared()
  }

  override fun isBusy(): Boolean = _state.value.probing

  override fun isWaitingForUser(): Boolean = _state.value.mode == LightMode.COLOUR && colourJob?.isActive != true

  override fun reminder(index: Int, last: Boolean): String? =
      if (_state.value.mode == LightMode.COLOUR) str(R.string.light_colour_reminder) else null

  // MARK: - Voice

  override fun onCommand(text: String): Boolean {
    val cmd = LightGrammar.parse(Phrases.normalize(text)) ?: return false
    Log.i(TAG, "command $cmd")
    hub.userActed()
    when (cmd) {
      LightCommand.HowBright -> howBright()
      LightCommand.WhereBright -> whereBright()
      LightCommand.IsBlinking -> isBlinking()
      LightCommand.Again -> if (_state.value.mode == LightMode.COLOUR) measureColour(first = false) else howBright()
      LightCommand.Colour -> toColour(announce = _state.value.mode != LightMode.COLOUR, first = false)
      LightCommand.Light -> toLight(announce = str(R.string.light_probe_on))
      LightCommand.ToneOff -> pauseTone()
      LightCommand.ToneOn -> toLight(announce = str(R.string.light_tone_on))
    }
    return true
  }

  override fun onGlobal(command: GlobalCommand): Boolean =
      when (command) {
        GlobalCommand.Pause ->
            if (_state.value.mode == LightMode.PROBE) {
              hub.userActed()
              pauseTone()
              true
            } else false
        GlobalCommand.Resume ->
            if (_state.value.mode == LightMode.PROBE) {
              hub.userActed()
              toLight(announce = str(R.string.light_tone_on))
              true
            } else false
        else -> false
      }

  // MARK: - Pitfalls: the tone never plays on without the glasses

  override fun onHealthAlert(alert: HealthAlert): String? {
    when (alert) {
      HealthAlert.GlassesRemoved, HealthAlert.GlassesDisconnected, HealthAlert.GlassesTooHot,
      HealthAlert.BluetoothOff -> stopProbe()
      HealthAlert.GlassesWornAgain -> resumeIfWanted()
      else -> Unit
    }
    return super.onHealthAlert(alert)
  }

  override fun onStreamLost(): Boolean {
    stopProbe()
    return true
  }

  override fun onStreamBack() = resumeIfWanted()

  private fun resumeIfWanted() {
    val s = _state.value
    if (attached && s.mode == LightMode.PROBE && !s.paused && !s.probing) startProbe(announce = null)
  }

  // MARK: - Modes

  /** Button handlers (the screen). */
  fun tapLight() {
    hub.userActed()
    toLight(announce = str(R.string.light_probe_on))
  }

  fun tapColour() {
    hub.userActed()
    toColour(announce = _state.value.mode != LightMode.COLOUR, first = false)
  }

  fun tapMeasure() {
    hub.userActed()
    measureColour(first = false)
  }

  fun tapHowBright() {
    hub.userActed()
    howBright()
  }

  fun tapTone() {
    hub.userActed()
    if (_state.value.probing) pauseTone() else toLight(announce = str(R.string.light_tone_on))
  }

  private fun toLight(announce: String?) {
    colourJob?.cancel()
    _state.update { it.copy(mode = LightMode.PROBE, paused = false) }
    startProbe(announce)
  }

  private fun toColour(announce: Boolean, first: Boolean) {
    stopProbe()
    _state.update { it.copy(mode = LightMode.COLOUR) }
    if (announce) say(str(R.string.light_colour_mode))
    measureColour(first = first || announce)
  }

  // MARK: - Light probe

  private fun startProbe(announce: String?) {
    if (probeJob?.isActive == true) {
      announce?.let { answer(it) }
      return
    }
    if (!hub.camera.isStreaming.value) {
      if (!hub.reconnectThen { startProbe(announce) }) hub.explainNoGlasses()
      return
    }
    announce?.let { answer(it) }
    smoother.reset()
    flicker.reset()
    lastFrameAt = SystemClock.elapsedRealtime()
    _state.update { it.copy(probing = true, paused = false, blinking = false, probeFrames = 0, probeFrameMs = 0f) }
    val fps = probeFps
    Log.i(TAG, "probe start at $fps fps")
    probeJob = viewModelScope.launch(Dispatchers.Default) {
      // Silence the tone if frames stop arriving: a stale pitch would mislead.
      launch {
        while (isActive) {
          delay(500)
          if (SystemClock.elapsedRealtime() - lastFrameAt > STALE_MS && tone.isPlaying) {
            synchronized(toneLock) { tone.stop() }
            _state.update { it.copy(toneHz = 0f) }
          }
        }
      }
      var totalMs = 0.0
      var n = 0
      hub.camera.frames(fps).collect { bmp ->
        val t0 = System.nanoTime()
        val (px, w, h) = sample(bmp, PROBE_WIDTH)
        val reading = LightMeter.measure(px, w, h)
        val hz = PitchMap.frequency(smoother.update(PitchMap.position(reading.luminance)))
        val blinking = flicker.update(px, w, h)
        totalMs += (System.nanoTime() - t0) / 1e6
        n++
        val now = SystemClock.elapsedRealtime()
        lastFrameAt = now
        lastReading = reading
        lastReadingAt = now
        var played = false
        synchronized(toneLock) {
          if (isActive && _state.value.probing) {
            tone.play(hz)
            played = true
          }
        }
        if (!played) return@collect
        val wasBlinking = _state.value.blinking
        _state.update {
          it.copy(toneHz = hz, level = LightMeter.level(reading), blinking = blinking,
              probeFrameMs = (totalMs / n).toFloat(), probeFrames = n)
        }
        if (n % 40 == 0) Log.i(TAG, "probe $n frames, %.2f ms/frame, hz=%.0f".format(totalMs / n, hz))
        if (blinking && !wasBlinking && now - lastBlinkSaidAt > BLINK_REPEAT_MS) {
          lastBlinkSaidAt = now
          withContext(Dispatchers.Main) { hub.sayAside(str(R.string.light_blinking)) }
        }
      }
    }
  }

  private fun stopProbe() {
    probeJob?.cancel()
    probeJob = null
    synchronized(toneLock) {
      _state.update { it.copy(probing = false, toneHz = 0f) }
      tone.stop()
    }
  }

  private fun pauseTone() {
    hub.hush()
    stopProbe()
    _state.update { it.copy(paused = true) }
    hub.sayAside(str(R.string.light_tone_off))
    onStatus(str(R.string.light_tone_off))
  }

  /** A fresh reading from the probe, or one measured from the latest frame now. */
  private suspend fun reading(): LightReading? {
    lastReading?.takeIf { _state.value.probing && SystemClock.elapsedRealtime() - lastReadingAt < 1_500 }?.let { return it }
    val bmp = hub.camera.latestFrame() ?: return null
    return withContext(Dispatchers.Default) {
      val (px, w, h) = sample(bmp, PROBE_WIDTH)
      LightMeter.measure(px, w, h)
    }
  }

  private fun howBright() = withReading { r ->
    val level =
        when (LightMeter.level(r)) {
          LightLevel.DARK -> R.string.light_level_dark
          LightLevel.DIM -> R.string.light_level_dim
          LightLevel.NORMAL -> R.string.light_level_normal
          LightLevel.BRIGHT -> R.string.light_level_bright
          LightLevel.VERY_BRIGHT -> R.string.light_level_very_bright
        }
    _state.update { it.copy(level = LightMeter.level(r)) }
    str(R.string.light_level, str(level))
  }

  private fun whereBright() = withReading { r ->
    str(
        when (r.brightestSide) {
          Side.LEFT -> R.string.light_brighter_left
          Side.RIGHT -> R.string.light_brighter_right
          Side.MIDDLE -> R.string.light_brighter_middle
          null -> R.string.light_even
        },
    )
  }

  private fun withReading(text: (LightReading) -> String) {
    if (!hub.camera.isStreaming.value) {
      if (!hub.reconnectThen { withReading(text) }) hub.explainNoGlasses()
      return
    }
    viewModelScope.launch {
      val r = reading()
      if (r == null) hub.warn(str(R.string.light_no_picture)) else answer(text(r))
    }
  }

  private fun isBlinking() {
    val s = _state.value
    if (s.mode != LightMode.PROBE || !s.probing) {
      toLight(announce = str(R.string.light_not_blinking))
      return
    }
    answer(str(if (s.blinking) R.string.light_blinking else R.string.light_not_blinking))
  }

  // MARK: - Colour

  private fun measureColour(first: Boolean) {
    if (colourJob?.isActive == true) return
    if (!hub.camera.isStreaming.value) {
      if (!hub.reconnectThen { measureColour(first) }) hub.explainNoGlasses()
      return
    }
    colourJob = viewModelScope.launch {
      val bmp = hub.camera.latestFrame()
      if (bmp == null) {
        hub.warn(str(R.string.light_no_picture))
        return@launch
      }
      val t0 = SystemClock.elapsedRealtime()
      val result = withContext(Dispatchers.Default) {
        val (px, w, h) = sample(bmp, COLOUR_WIDTH)
        ColourReader.read(px, w, h)
      }
      val text = ColourSpeech.describe(result)
      Log.i(TAG, "colour in ${SystemClock.elapsedRealtime() - t0} ms: $text confidence=${result.confidence} " +
          "reasons=${result.reasons} cast=%.2f warmth=%.2f frameLuma=%.0f".format(result.whiteBalance.cast, result.whiteBalance.warmth, result.frameLuma))
      _state.update { it.copy(colourText = text, colour = result, swatch = result.swatch) }
      if (first) say(text) else answer(text)
    }
  }

  /** An answer to a command: the command already played ACK, so cut off and speak. */
  private fun answer(text: String) {
    hub.hush()
    say(text)
  }

  class Factory(private val application: Application, private val hub: ToolHub) :
      ViewModelProvider.Factory {
    override fun <T : ViewModel> create(modelClass: Class<T>): T {
      @Suppress("UNCHECKED_CAST")
      return LightViewModel(application, hub) as T
    }
  }

  companion object {
    private const val TAG = "LightTool"
    const val DEFAULT_PROBE_FPS = 4f
    /** Probe frames are scaled to this width (96x172 for a 480x864 stream). */
    const val PROBE_WIDTH = 96
    /** Colour frames are scaled to this width (160x288): the centre patch is then 32x32. */
    const val COLOUR_WIDTH = 160
    private const val STALE_MS = 2_000L
    private const val BLINK_REPEAT_MS = 10_000L

    /** [bmp] scaled to [width] (keeping its shape), as packed ARGB pixels. */
    fun sample(bmp: Bitmap, width: Int): Triple<IntArray, Int, Int> {
      val w = width.coerceAtMost(bmp.width)
      val h = (bmp.height.toLong() * w / bmp.width).toInt().coerceAtLeast(1)
      val small = Bitmap.createScaledBitmap(bmp, w, h, true)
      val px = IntArray(w * h)
      small.getPixels(px, 0, w, 0, 0, w, h)
      if (small !== bmp) small.recycle()
      return Triple(px, w, h)
    }
  }
}
