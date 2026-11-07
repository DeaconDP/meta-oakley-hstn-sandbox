// ToolHub - the voice-first runtime every tool shares
//
// One per activity, next to CameraViewModel (which owns the DAT session and stream). It was lifted
// out of the book reader so each new tool gets, by composition, everything that makes the book
// reader usable without the screen:
//
//   link       connectAndStream with narration ("Connecting to your glasses", "Your glasses are
//              ready", or the most specific reason they can't be reached), permission narration,
//              a quiet reconnect loop after a fold, "the camera is back".
//   voice      VoiceControl (glasses mic, phone fallback) + EchoGuard; every final transcript goes
//              to the open tool's grammar first (ToolHost.onCommand), then GlobalGrammar.
//   speech     one ToolSpeaker (accessibility audio) + Earcons + ToneSynth. sayAside() is a short
//              note; reply() cuts off what's being said, answers, and lets the tool carry on.
//   pitfalls   GlassesWatch + HealthMonitor: Bluetooth, battery, heat, taken off, disconnected,
//              update required, each spoken once when it changes (ToolHost.onHealthAlert to act).
//   reminders  IdleNudge: when the tool is waiting for the user and it's quiet, say what to do.
//   switching  "read my mail" in any tool: the old tool's onLeaving (the book saves its bookmark),
//              "Mail reader.", the new tool attaches. The DAT session, stream and mic stay up.
//   ask        GlobalCommand.Ask -> AskAboutText with the tool's RecentText -> spoken answer.
//
// The UI decides which tool screen shows from [activeTool]; each tool screen attaches its
// ViewModel (ToolScreenEffects). Main thread only, except where noted.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools

import android.app.Application
import android.content.Context
import android.os.SystemClock
import android.util.Log
import androidx.annotation.StringRes
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.meta.wearable.dat.core.Wearables
import com.meta.wearable.dat.core.types.Permission
import com.meta.wearable.dat.core.types.PermissionStatus
import com.meta.wearable.dat.externalsampleapps.cameraaccess.R
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ask.AskProvider
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.AskAboutText
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.AskResult
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.BatteryLevel
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.EchoGuard
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.GlassesSnapshot
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.GlobalCommand
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.GlobalGrammar
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.HealthAlert
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.HealthMonitor
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.IdleNudge
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.Phrases
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.PhoneSnapshot
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.RecentText
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolRequest
import java.util.Locale
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

class ToolHub(
    application: Application,
    /** The glasses camera (CameraViewModel). */
    val camera: PageCamera,
) : AndroidViewModel(application), ToolSpeaker.Listener {

  companion object {
    private const val TAG = "ToolHub"
    private const val PREFS = "tools"
    private const val KEY_RATE = "speech_rate"
    private const val LINK_WAIT_MS = 20_000L
    private const val SORRY_GAP_MS = 8_000L
    private const val SORRY_MAX_WORDS = 6
    private const val STREAM_LOST_SAY_DELAY_MS = 1_500L
    private const val ALERT_EXPLAINS_MS = 4_000L
    private const val RECONNECT_EVERY_MS = 4_000L
    private const val NUDGE_CHECK_MS = 1_000L
    private const val SPOKEN_LOG_SIZE = 50
    const val MIN_RATE = 0.5f
    const val MAX_RATE = 3f
  }

  private val prefs = application.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

  // MARK: - What tools use directly

  /** Speech for every tool. Prefer [sayAside]/[reply]/[speak], which keep the echo guard right. */
  private val speaker = ToolSpeaker(application, this)
  val earcons = Earcons()
  /** Pitch-carrying tones (light probe, direction cues). */
  val tones = ToneSynth()
  /** Text each tool has read, for questions about it. Tools publish; AskAboutText reads. */
  val recentText = RecentText()
  /** Answers questions about [recentText]. Not ready yet: tools/ask/AskProvider. */
  var askAboutText: AskAboutText = AskProvider.create(application)

  private val voice = VoiceControl(application, viewModelScope)
  private val echo = EchoGuard()
  private val nudge = IdleNudge()
  private val watch = GlassesWatch(application)
  private val health = HealthMonitor()

  /** Which microphone voice control is using. */
  val microphone: StateFlow<Microphone> = voice.microphone

  private val _activeTool = MutableStateFlow<ToolRequest?>(null)
  /** The tool whose screen is showing, or null for the camera screen. */
  val activeTool: StateFlow<ToolRequest?> = _activeTool.asStateFlow()

  /** Latest glasses/phone readings (battery, worn, Bluetooth...), null until the watch reports. */
  var glassesNow: GlassesSnapshot? = null
    private set
  var phoneNow: PhoneSnapshot? = null
    private set

  /** A short note is being spoken (sayAside); tools reading text wait for it. */
  var isSpeakingAside = false
    private set

  /** The stream dropped while a tool was open and hasn't come back yet. */
  var streamLost = false
    private set

  /** The shared tools speech rate (tools that don't keep their own; see ToolHost.speechRate). */
  var sharedRate: Float = prefs.getFloat(KEY_RATE, 1f)
    private set

  // MARK: - State

  private var host: ToolHost? = null
  private var hostRequest: ToolRequest? = null
  private var pendingReason = OpenReason.TAPPED
  private val attached = MutableStateFlow<ToolHost?>(null)
  private var engineAvailable: Boolean? = null
  private var lastSaid: String? = null
  private val spokenLog = ArrayDeque<String>()
  private var lastSorryMs = 0L
  private var lastAlertMs = 0L
  private var voiceJob: Job? = null
  /** openVoice has done its first welcome; later tools are greeted by [attach]. */
  private var welcomed = false
  private var reconnectJob: Job? = null
  private var reconnectLoop: Job? = null
  private var requestPermission: (suspend (Permission) -> PermissionStatus)? = null
  private var phoneAllowed: (suspend () -> Boolean)? = null

  init {
    // A fold or session end stops the stream; the open tool decides whether that matters.
    viewModelScope.launch {
      camera.isStreaming.drop(1).collect { streaming ->
        val h = host
        if (!streaming && h != null && h.onStreamLost()) onStreamLost()
        if (streaming && streamLost) onStreamBack()
      }
    }
  }

  // MARK: - Opening, switching and closing tools

  /** Shows [request]'s tool. [voiceFirst]: launched straight into it, so connect and narrate. */
  fun open(request: ToolRequest, voiceFirst: Boolean = false) {
    if (_activeTool.value?.tool == request.tool) {
      _activeTool.value = request
      host?.takeIf { it.toolId == request.tool }?.onRequest(request)
      return
    }
    host?.onLeaving()
    pendingReason = if (voiceFirst) OpenReason.LAUNCHED else OpenReason.TAPPED
    _activeTool.value = request
  }

  /**
   * By voice, from inside a tool: the current tool leaves (saving its state), ToolHub says the new
   * tool's name, and the new one opens. The glasses session, stream and mic stay up.
   */
  fun switchTo(request: ToolRequest) {
    val current = _activeTool.value
    if (current?.tool == request.tool) {
      _activeTool.value = request
      host?.onRequest(request)
      return
    }
    Log.i(TAG, "switch ${current?.tool?.id} -> ${request.tool.id} mode=${request.mode} arg=${request.argument}")
    earcons.play(Earcon.SWITCH)
    host?.onLeaving()
    hush()
    pendingReason = OpenReason.SWITCHED
    _activeTool.value = request
    sayAside(getApplication<Application>().getString(R.string.tool_switched, toolName(request.tool)))
  }

  /** Back to the camera screen (close button, back, or "close"). */
  fun closeTool() {
    host?.onLeaving()
    _activeTool.value = null
  }

  /** "close" by voice in a tool that doesn't handle it: leave, saying goodbye. */
  fun closeByVoice() {
    val h = host
    h?.onLeaving()
    sayAside(h?.texts()?.goodbye ?: str(R.string.tool_goodbye))
    _activeTool.value = null
  }

  /** The tool's spoken name ("Mail reader"). */
  fun toolName(id: ToolId): String = getApplication<Application>().getString(ToolRegistry.spec(id).nameRes)

  /** Called by the tool's screen when it opens. */
  fun attach(tool: ToolHost, request: ToolRequest) {
    if (host === tool) return
    host?.onDetached()
    host = tool
    hostRequest = request
    attached.value = tool
    (tool.speechRate() ?: sharedRate).let { speaker.setRate(it) }
    engineAvailable?.let { tool.onEngineState(it) }
    tool.onAttached(request)
    // Voice already running: this is a switch (or a re-open); the tool talks now. Otherwise
    // openVoice does the welcome first and then calls onOpened.
    if (welcomed) {
      val reason = pendingReason
      if (reason == OpenReason.SWITCHED) {
        tool.texts().welcomeAfterSwitch.takeIf { it.isNotBlank() }?.let { sayAside(it) }
      } else {
        sayAside(tool.texts().welcome)
      }
      tool.onOpened(request, reason)
    }
  }

  /** Called by the tool's screen when it closes. */
  fun detach(tool: ToolHost) {
    if (host !== tool) return
    tool.onDetached()
    host = null
    hostRequest = null
    attached.value = null
  }

  // MARK: - Voice lifecycle

  /**
   * Starts listening while any tool is open (the UI calls it once, not per tool, so switching keeps
   * the mic). [voiceFirst]: launched straight into a tool, so bring the link up without dialogs and
   * narrate each step.
   */
  fun openVoice(
      voiceFirst: Boolean,
      requestWearablesPermission: suspend (Permission) -> PermissionStatus,
      requestRecordAudio: suspend () -> Boolean,
  ) {
    if (voiceJob?.isActive == true) return
    requestPermission = requestWearablesPermission
    phoneAllowed = requestRecordAudio
    voiceJob = viewModelScope.launch {
      // Everything that can go wrong around the tool is spoken when it changes.
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
      // A quiet user gets told what the tool is waiting for.
      launch { remindWhenQuiet() }
      // Permission trouble, whoever started the connection.
      launch {
        camera.link.drop(1).collect { link ->
          when (link) {
            CameraLink.NEEDS_PERMISSION -> sayAside(str(R.string.voice_camera_permission))
            CameraLink.CAMERA_DENIED -> warn(host?.texts()?.cameraDenied ?: str(R.string.tool_camera_denied))
            else -> Unit
          }
        }
      }
      val first = attached.filterNotNull().first()
      if (voiceFirst && !camera.isStreaming.value) {
        bringUpLink(requestWearablesPermission, first)
      } else {
        sayAside(first.texts().welcome)
      }
      host?.let { h -> hostRequest?.let { h.onOpened(it, pendingReason) } }
      welcomed = true
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
      voice.utterances.collect { onUtterance(it.text, it.isFinal) }
    }
  }

  /** Stops listening (no tool open any more). Speech already queued (a goodbye) still plays. */
  fun closeVoice() {
    voiceJob?.cancel()
    voiceJob = null
    welcomed = false
    reconnectJob?.cancel()
    reconnectLoop?.cancel()
    requestPermission = null
    phoneAllowed = null
    voice.stop()
  }

  val isVoiceOpen: Boolean
    get() = voiceJob?.isActive == true

  private suspend fun bringUpLink(
      requestPermission: suspend (Permission) -> PermissionStatus,
      tool: ToolHost,
  ) {
    val narration = viewModelScope.launch {
      camera.link.collect { link ->
        if (link == CameraLink.CONNECTING) sayAside(tool.texts().connecting)
      }
    }
    camera.connectAndStream(requestPermission)
    val up = withTimeoutOrNull(LINK_WAIT_MS) { camera.isStreaming.first { it } }
    narration.cancel()
    if (up == true) {
      earcons.play(Earcon.PAGE_DONE)
      sayAside(tool.texts().ready)
    } else {
      explainNoGlasses()
      // Keep waiting quietly; welcome the user when the glasses turn up.
      viewModelScope.launch {
        camera.isStreaming.first { it }
        sayAside((host ?: tool).texts().ready)
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

  /**
   * One transcript from the mic. Public so tests can drive it without audio. Echoes of our own
   * speech are dropped; partials go to the tool (barge-in); a final transcript goes to the tool's
   * grammar, then the global one.
   */
  fun onUtterance(text: String, isFinal: Boolean) {
    val now = SystemClock.elapsedRealtime()
    if (echo.isEcho(text, now)) {
      if (isFinal) Log.i(TAG, "voice echo ignored: \"$text\"")
      return
    }
    val h = host ?: return
    if (!isFinal) {
      h.onPartial(text)
      return
    }
    // Even speech that isn't a command means the user is there: no reminder needed yet.
    nudge.userActed(now)
    h.onHeard(text)
    if (h.onCommand(text)) return
    val command = GlobalGrammar.parse(text)
    Log.i(TAG, "voice heard=\"$text\" tool=${h.toolId.id} global=$command")
    if (command == null) {
      h.onNotUnderstood(text)
      return
    }
    if (h.onGlobal(command)) return
    handleGlobal(h, command)
  }

  /** ToolHub's default for each global command. Tools override with ToolHost.onGlobal. */
  fun handleGlobal(h: ToolHost, command: GlobalCommand) {
    when (command) {
      is GlobalCommand.Open ->
          if (command.request.tool == h.toolId) {
            userActed()
            _activeTool.value = command.request
            h.onRequest(command.request)
          } else {
            switchTo(command.request)
          }
      is GlobalCommand.Ask -> ask(command)
      GlobalCommand.Pause -> {
        hush()
        sayAside(str(R.string.voice_paused))
      }
      GlobalCommand.Resume -> reply(h.texts().welcome)
      GlobalCommand.Repeat -> reply(lastSaid ?: h.texts().welcome)
      is GlobalCommand.Faster -> changeSharedRate(sharedRate + command.step)
      is GlobalCommand.Slower -> changeSharedRate(sharedRate - command.step)
      is GlobalCommand.SetRate -> changeSharedRate(command.rate)
      GlobalCommand.Help -> reply(h.texts().help)
      GlobalCommand.Battery -> reply(batteryReport())
      GlobalCommand.Close -> closeByVoice()
    }
  }

  /** "Sorry, I didn't get that", but not while [busy] (reading: probably the room), not for long
   * speech, and at most every 8 s. */
  fun sayNotUnderstood(text: String, busy: Boolean) {
    if (busy) return
    if (Phrases.wordCount(text) > SORRY_MAX_WORDS) return
    val now = SystemClock.elapsedRealtime()
    if (now - lastSorryMs < SORRY_GAP_MS) return
    lastSorryMs = now
    reply(str(R.string.voice_not_understood))
  }

  // MARK: - Asking about the text

  /** Answers a question about what the open tool read (RecentText), out loud. */
  fun ask(question: GlobalCommand.Ask) {
    earcons.play(Earcon.ACK)
    val tool = host?.toolId
    val snapshot = recentText.forQuestion(tool)
    Log.i(TAG, "ask \"${question.question}\" subject=${question.subject} text=${snapshot?.tool?.id}:${snapshot?.fullText?.length}")
    viewModelScope.launch {
      val result =
          try {
            askAboutText.answer(question, snapshot) { note -> sayAside(note) }
          } catch (e: CancellationException) {
            throw e
          } catch (e: Exception) {
            AskResult.Failed(e.message)
          }
      Log.i(TAG, "ask result=$result")
      reply(
          when (result) {
            is AskResult.Answer -> result.text
            AskResult.NotInText -> str(R.string.tool_ask_not_in_text)
            AskResult.NothingRead -> str(R.string.tool_ask_nothing_read)
            AskResult.Unavailable -> str(R.string.tool_ask_unavailable)
            is AskResult.Failed -> str(R.string.tool_ask_failed)
          },
      )
    }
  }

  // MARK: - Speaking

  /** Short spoken note (status, hint, reply). The tool's ToolHost.onAsideDone runs after it. */
  fun sayAside(text: String) {
    isSpeakingAside = true
    remember(text)
    speaker.speak(text, "aside")
  }

  /** Tool content (a sentence of a page). ToolHost.onSpoken([tag]) runs when it finishes. */
  fun speak(text: String, tag: String) {
    require(tag != "aside") { "\"aside\" is reserved for sayAside" }
    remember(text)
    speaker.speak(text, tag)
  }

  private fun remember(text: String) {
    lastSaid = text
    synchronized(spokenLog) {
      spokenLog.addLast(text)
      while (spokenLog.size > SPOKEN_LOG_SIZE) spokenLog.removeFirst()
    }
  }

  /**
   * The last few things sent to speech (asides and tool content), oldest first. For tests, which
   * can't hear: "did it say X?" (whether or not it was later cut off).
   */
  fun recentSpeech(): List<String> = synchronized(spokenLog) { spokenLog.toList() }

  /** Answer now: cut off what's being said, speak [text], then the tool carries on (onAsideDone). */
  fun reply(text: String) {
    earcons.play(Earcon.ACK)
    hush()
    sayAside(text)
  }

  /** A problem: error earcon, status line, then interrupt and say it. */
  fun warn(text: String) {
    earcons.play(Earcon.ERROR)
    host?.onStatus(text)
    reply(text)
  }

  /** Status line plus a spoken note. */
  fun say(text: String) {
    host?.onStatus(text)
    sayAside(text)
  }

  /** Stops speech now, drops what's queued, and tells the echo guard it ended. */
  fun hush() {
    speaker.stop()
    isSpeakingAside = false
    echo.finished(SystemClock.elapsedRealtime())
  }

  /** Sets the speech rate now (the tool keeps and persists its own value if it has one). */
  fun setRate(rate: Float) {
    speaker.setRate(rate)
  }

  /** A button press or command: acknowledge it, and start silence reminders over. */
  fun userActed() {
    earcons.play(Earcon.ACK)
    nudge.userActed(SystemClock.elapsedRealtime())
  }

  private fun changeSharedRate(requested: Float) {
    val before = sharedRate
    val r = (Math.round(requested * 10f) / 10f).coerceIn(MIN_RATE, MAX_RATE)
    sharedRate = r
    prefs.edit().putFloat(KEY_RATE, r).apply()
    speaker.setRate(r)
    reply(rateReply(before, requested, r))
  }

  /** "1.5 times speed.", or "already the fastest/slowest". */
  fun rateReply(before: Float, requested: Float, after: Float): String =
      when {
        after == before && requested > before -> str(R.string.voice_rate_fastest)
        after == before && requested < before -> str(R.string.voice_rate_slowest)
        else -> getApplication<Application>().getString(R.string.voice_rate, formatRate(after))
      }

  fun formatRate(rate: Float): String =
      if (rate % 1f == 0f) rate.toInt().toString()
      else String.format(Locale.US, "%.2f", rate).trimEnd('0')

  override fun onUtteranceStarted(text: String) {
    echo.spoke(text, SystemClock.elapsedRealtime())
  }

  override fun onSpoken(tag: String) {
    echo.finished(SystemClock.elapsedRealtime())
    if (tag == "aside") {
      isSpeakingAside = false
      host?.onAsideDone()
    } else {
      host?.onSpoken(tag)
    }
  }

  override fun onEngineState(available: Boolean) {
    engineAvailable = available
    // No voice at all: the only thing left to signal with is sound.
    if (!available) earcons.play(Earcon.ERROR)
    host?.onEngineState(available)
  }

  // MARK: - Silence reminders

  private suspend fun remindWhenQuiet() {
    nudge.userActed(SystemClock.elapsedRealtime())
    while (true) {
      delay(NUDGE_CHECK_MS)
      val now = SystemClock.elapsedRealtime()
      val h = host
      if (h == null || !quiet() || !h.isWaitingForUser()) {
        nudge.busy(now)
        continue
      }
      val reminder = nudge.due(now) ?: continue
      val text = h.reminder(reminder, nudge.isLast(reminder)) ?: continue
      Log.i(TAG, "nudge reminder=$reminder text=$text")
      sayAside(text)
    }
  }

  /** Nothing of ToolHub's own going on: not talking, not reconnecting, glasses streaming. */
  private fun quiet(): Boolean =
      !isSpeakingAside && reconnectJob?.isActive != true && !streamLost && camera.isStreaming.value

  // MARK: - Link: lost, back, reconnect

  private fun onStreamLost() {
    earcons.play(Earcon.ERROR)
    streamLost = true
    val pausedByGlasses = camera.link.value == CameraLink.PAUSED
    if (!pausedByGlasses) keepTryingToReconnect()
    viewModelScope.launch {
      // A health alert ("glasses disconnected", "taken off") usually explains it better; give it
      // a moment to arrive and only speak the generic line if nothing did.
      delay(STREAM_LOST_SAY_DELAY_MS)
      if (camera.isStreaming.value) return@launch
      val texts = host?.texts() ?: return@launch
      val now = SystemClock.elapsedRealtime()
      when {
        pausedByGlasses -> sayAside(texts.pausedByGlasses)
        now - lastAlertMs > ALERT_EXPLAINS_MS -> sayAside(texts.streamLost)
      }
    }
  }

  /**
   * Folding (or a session ending) doesn't always show up as a link change, so while the stream is
   * lost and a tool is open, quietly try to bring it back whenever the glasses look reachable.
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
    host?.onStreamBack()
    if (voiceJob?.isActive != true) return
    earcons.play(Earcon.PAGE_DONE)
    say(host?.texts()?.cameraBack ?: str(R.string.tool_camera_back))
    restartVoiceOnGlasses()
  }

  /**
   * Not streaming but the user wants the camera: bring the link up (narrated), then run [then]. If
   * it doesn't come up, say why. Returns false if it can't even try (voice not open, so no way to
   * ask for permission); the tool should then say so itself.
   */
  fun reconnectThen(then: () -> Unit): Boolean {
    val rp = requestPermission ?: return false
    if (reconnectJob?.isActive == true) return true
    sayAside(host?.texts()?.connecting ?: str(R.string.tool_reconnecting))
    camera.connectAndStream(rp)
    reconnectJob = viewModelScope.launch {
      val up = withTimeoutOrNull(LINK_WAIT_MS) { camera.isStreaming.first { it } }
      if (up == true) then() else explainNoGlasses()
    }
    return true
  }

  /** True while [reconnectThen] is waiting for the link. */
  val isReconnecting: Boolean
    get() = reconnectJob?.isActive == true

  /** The most specific reason the glasses can't be reached, spoken. */
  fun explainNoGlasses() {
    earcons.play(Earcon.ERROR)
    val g = glassesNow
    val p = phoneNow
    val cameraDenied = camera.link.value == CameraLink.CAMERA_DENIED
    sayAside(
        when {
          p?.bluetoothOn == false -> str(R.string.health_bluetooth_off)
          g?.paired == false -> str(R.string.health_no_glasses)
          g?.updateRequired == true -> str(R.string.health_update_required)
          cameraDenied -> host?.texts()?.cameraDenied ?: str(R.string.tool_camera_denied)
          g?.connected == true && g.worn == false -> str(R.string.health_removed)
          else -> str(R.string.voice_no_glasses)
        },
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
      val override = host?.onHealthAlert(alert)
      val app = getApplication<Application>()
      fun text(@StringRes id: Int) = override ?: str(id)
      when (alert) {
        HealthAlert.BluetoothOff -> warn(text(R.string.health_bluetooth_off))
        HealthAlert.BluetoothOn -> say(text(R.string.health_bluetooth_on))
        HealthAlert.NoGlassesPaired -> warn(text(R.string.health_no_glasses))
        HealthAlert.GlassesDisconnected -> warn(text(R.string.health_disconnected))
        HealthAlert.GlassesConnected -> {
          say(text(R.string.health_connected))
          // Bring the camera back by itself; onStreamBack says when it's ready.
          if (!camera.isStreaming.value) requestPermission?.let { camera.connectAndStream(it) }
        }
        HealthAlert.GlassesRemoved -> warn(text(R.string.health_removed))
        HealthAlert.GlassesWornAgain -> say(text(R.string.health_worn_again))
        HealthAlert.UpdateRequired -> warn(text(R.string.health_update_required))
        is HealthAlert.GlassesBattery ->
            warn(
                override
                    ?: app.getString(
                        if (alert.level == BatteryLevel.CRITICAL) R.string.health_glasses_battery_critical
                        else R.string.health_glasses_battery_low,
                        alert.percent,
                    ),
            )
        is HealthAlert.PhoneBattery ->
            warn(override ?: app.getString(R.string.health_phone_battery_low, alert.percent))
        HealthAlert.GlassesHot -> warn(text(R.string.health_hot))
        HealthAlert.GlassesTooHot -> warn(text(R.string.health_too_hot))
        HealthAlert.GlassesCooled -> say(text(R.string.health_cooled))
      }
    }
  }

  /** Glasses and phone battery, as a sentence. */
  fun batteryReport(): String {
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

  private fun str(@StringRes id: Int): String = getApplication<Application>().getString(id)

  override fun onCleared() {
    super.onCleared()
    voice.stop()
    speaker.shutdown()
    earcons.release()
    tones.release()
  }

  class Factory(
      private val application: Application,
      private val camera: PageCamera,
  ) : ViewModelProvider.Factory {
    override fun <T : ViewModel> create(modelClass: Class<T>): T {
      if (modelClass.isAssignableFrom(ToolHub::class.java)) {
        @Suppress("UNCHECKED_CAST")
        return ToolHub(application, camera) as T
      }
      throw IllegalArgumentException("Unknown ViewModel class")
    }
  }
}
