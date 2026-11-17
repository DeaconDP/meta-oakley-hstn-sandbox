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
//   home       the home voice menu: with home=true, voice runs for the whole camera screen, not just
//              while a tool is open. With no tool open, transcripts go to GlobalGrammar.parseHome
//              ("read my mail" opens it, "what can I say", "close the app" leaves). "Main menu" in
//              any tool comes back here. See notes/tools-layer.md > Home voice menu.
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

    /** Intent extra: `--ez home_voice false` keeps the camera screen touch-only (benchmarking). */
    const val EXTRA_HOME_VOICE = "home_voice"

    /**
     * The home voice menu on the camera screen. On by default; the touch-driven bench tests
     * (InstrumentationTest, BookReaderTest's tap cases) turn it off so the session doesn't start
     * by itself under their taps.
     */
    @Volatile @JvmStatic var homeMenuEnabled: Boolean = true
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

  private val _homeHeard = MutableStateFlow("")
  /** The last thing heard in the home menu (for the camera screen). */
  val homeHeard: StateFlow<String> = _homeHeard.asStateFlow()

  private val _homeStatus = MutableStateFlow("")
  /** The last thing said in the home menu (for the camera screen). */
  val homeStatus: StateFlow<String> = _homeStatus.asStateFlow()

  /**
   * Set by the camera screen: end the glasses session and step aside (moveTaskToBack). Called after
   * voice has stopped, so the goodbye still plays.
   */
  var onExitApp: (() -> Unit)? = null

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
  /** Voice runs for the whole camera screen with a home menu (openVoice(home = true)). */
  private var homeMenu = false
  /** The open tool was launched straight into (alias, deep link, extra) and nothing else since. */
  private var launchedStraightIn = false
  private var requestPermission: (suspend (Permission) -> PermissionStatus)? = null
  private var phoneAllowed: (suspend () -> Boolean)? = null

  init {
    // A fold or session end stops the stream; the open tool decides whether that matters.
    viewModelScope.launch {
      camera.isStreaming.drop(1).collect { streaming ->
        val h = host
        if (!streaming && (h?.onStreamLost() ?: isHome)) onStreamLost()
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
    if (_activeTool.value != null) host?.onLeaving()
    pendingReason = if (voiceFirst) OpenReason.LAUNCHED else OpenReason.TAPPED
    launchedStraightIn = voiceFirst
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
    if (current != null) host?.onLeaving()
    hush()
    pendingReason = OpenReason.SWITCHED
    launchedStraightIn = false
    _activeTool.value = request
    sayAside(getApplication<Application>().getString(R.string.tool_switched, toolName(request.tool)))
  }

  /**
   * Closing the open tool leaves the app: true for a tool launched straight into (launcher alias,
   * deep link, extra) that the user hasn't navigated away from, and always without the home menu
   * (the old behaviour). False when closing goes back to the home menu. A tool that says its own
   * goodbye checks this first.
   */
  val closeLeavesApp: Boolean
    get() = !homeMenu || launchedStraightIn

  /**
   * Back from the tool (close button, back, or the tool's own "close", which already said goodbye).
   * With the home menu: back to it ("Main menu."), or, for a tool launched straight into, out of
   * the app. Without it: back to the camera screen.
   */
  fun closeTool() = leaveTool(sayGoodbye = false)

  /** "close" by voice in a tool that doesn't handle it: as [closeTool], saying goodbye if leaving. */
  fun closeByVoice() = leaveTool(sayGoodbye = true)

  private fun leaveTool(sayGoodbye: Boolean) {
    val h = host
    if (_activeTool.value == null) return
    if (homeMenu && !launchedStraightIn) {
      Log.i(TAG, "close ${_activeTool.value?.tool?.id} -> home menu")
      h?.onLeaving()
      _activeTool.value = null
      backToMenu(cutOff = false)
      return
    }
    h?.onLeaving()
    if (sayGoodbye) sayAside(h?.texts()?.goodbye ?: str(R.string.tool_goodbye))
    _activeTool.value = null
    if (homeMenu) exitApp(sayGoodbye = false)
  }

  /** "Main menu" in a tool: leave it (saving its state) and go back to the home menu. */
  fun goHome() {
    val current = _activeTool.value
    if (current == null) {
      homeReply(homePrompt())
      return
    }
    Log.i(TAG, "main menu from ${current.tool.id}")
    earcons.play(Earcon.SWITCH)
    host?.onLeaving()
    _activeTool.value = null
    backToMenu(cutOff = true)
  }

  /** Arrived in the home menu from a tool: say so, briefly. */
  private fun backToMenu(cutOff: Boolean) {
    launchedStraightIn = false
    nudge.userActed(SystemClock.elapsedRealtime())
    if (!isVoiceOpen) return
    if (cutOff) hush()
    _homeHeard.value = ""
    homeSay(str(R.string.home_back))
  }

  /**
   * "Close the app" (or "close" in the menu): leave the open tool, say goodbye, stop listening, and
   * let the screen end the glasses session and step aside ([onExitApp]).
   */
  fun exitApp(sayGoodbye: Boolean = true) {
    val tool = _activeTool.value
    Log.i(TAG, "exit app from ${tool?.tool?.id ?: "home"}")
    if (tool != null) host?.onLeaving()
    if (sayGoodbye) {
      hush()
      sayAside((if (tool != null) host?.texts()?.goodbye else null) ?: str(R.string.tool_goodbye))
    }
    _activeTool.value = null
    launchedStraightIn = false
    closeVoice()
    onExitApp?.invoke()
  }

  /** Voice is running with a home menu to go back to ("main menu" works). */
  val hasHomeMenu: Boolean
    get() = homeMenu && isVoiceOpen

  /** In the home voice menu: listening, with no tool open. */
  val isHome: Boolean
    get() = homeMenu && isVoiceOpen && _activeTool.value == null

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
   * narrate each step. [home]: the home voice menu; voice runs for the whole camera screen (until
   * [closeVoice]) and, if no tool is open, the link comes up the voice-first way and the menu
   * welcomes the user.
   */
  fun openVoice(
      voiceFirst: Boolean,
      requestWearablesPermission: suspend (Permission) -> PermissionStatus,
      requestRecordAudio: suspend () -> Boolean,
      home: Boolean = false,
  ) {
    if (voiceJob?.isActive == true) return
    homeMenu = home
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
      if (home && _activeTool.value == null) {
        // The home menu: connect the voice-first way (no dialogs, narrated), then welcome.
        nudge.userActed(SystemClock.elapsedRealtime())
        if (!camera.isStreaming.value) {
          bringUpLink(
              requestWearablesPermission,
              connecting = { str(R.string.tool_reconnecting) },
              ready = { host?.texts()?.ready ?: str(R.string.home_welcome) },
              onReady = { text -> if (host == null) homeSay(text) else sayAside(text) },
          )
        } else {
          homeSay(str(R.string.home_welcome))
        }
        // A tool tapped open while the link came up hasn't been told to start yet.
        host?.let { h -> hostRequest?.let { h.onOpened(it, pendingReason) } }
      } else {
        val first = attached.filterNotNull().first()
        if (voiceFirst && !camera.isStreaming.value) {
          bringUpLink(
              requestWearablesPermission,
              connecting = { first.texts().connecting },
              ready = { (host ?: first).texts().ready },
          )
        } else {
          sayAside(first.texts().welcome)
        }
        host?.let { h -> hostRequest?.let { h.onOpened(it, pendingReason) } }
      }
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
    homeMenu = false
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
      connecting: () -> String,
      ready: () -> String,
      onReady: (String) -> Unit = { sayAside(it) },
  ) {
    val narration = viewModelScope.launch {
      camera.link.collect { link ->
        if (link == CameraLink.CONNECTING) sayAside(connecting())
      }
    }
    camera.connectAndStream(requestPermission)
    val up = withTimeoutOrNull(LINK_WAIT_MS) { camera.isStreaming.first { it } }
    narration.cancel()
    if (up == true) {
      earcons.play(Earcon.PAGE_DONE)
      onReady(ready())
    } else {
      explainNoGlasses()
      // Keep waiting quietly; welcome the user when the glasses turn up (unless they left).
      val listening = voiceJob
      viewModelScope.launch {
        camera.isStreaming.first { it }
        if (listening == null || listening.isActive) onReady(ready())
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
    if (isHome) {
      onHomeUtterance(text, isFinal, now)
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
      GlobalCommand.Help ->
          reply(if (hasHomeMenu) h.texts().help + " " + str(R.string.home_help_in_tool) else h.texts().help)
      GlobalCommand.Battery -> reply(batteryReport())
      GlobalCommand.Close -> closeByVoice()
      GlobalCommand.Home -> goHome()
      GlobalCommand.ExitApp -> exitApp()
    }
  }

  // MARK: - Home voice menu

  /** A transcript with no tool open: GlobalGrammar.parseHome, then the menu's own handling. */
  private fun onHomeUtterance(text: String, isFinal: Boolean, now: Long) {
    if (!isFinal) {
      if (GlobalGrammar.isBargeIn(text)) hush()
      return
    }
    nudge.userActed(now)
    _homeHeard.value = text
    val command = GlobalGrammar.parseHome(text)
    Log.i(TAG, "voice heard=\"$text\" tool=home global=$command")
    when (command) {
      null -> sayNotUnderstood(text, busy = false)
      // As if switched to from another tool: earcon, the tool's name, then the tool talks.
      is GlobalCommand.Open -> switchTo(command.request)
      is GlobalCommand.Ask -> ask(command)
      GlobalCommand.Pause -> hush()
      GlobalCommand.Resume, GlobalCommand.Home -> homeReply(homePrompt())
      GlobalCommand.Repeat -> homeReply(lastSaid ?: homePrompt())
      is GlobalCommand.Faster -> changeSharedRate(sharedRate + command.step)
      is GlobalCommand.Slower -> changeSharedRate(sharedRate - command.step)
      is GlobalCommand.SetRate -> changeSharedRate(command.rate)
      GlobalCommand.Help -> homeReply(str(R.string.home_help))
      GlobalCommand.Battery -> homeReply(batteryReport())
      // Nothing above the menu: "close", "goodbye", "quit" leave the app.
      GlobalCommand.Close, GlobalCommand.ExitApp -> exitApp()
    }
  }

  /** "Main menu. Say read my book, ..." */
  private fun homePrompt(): String = str(R.string.home_prompt)

  /** The menu's spoken line, also shown on the camera screen. */
  private fun homeSay(text: String) {
    _homeStatus.value = text
    sayAside(text)
  }

  private fun homeReply(text: String) {
    _homeStatus.value = text
    reply(text)
  }

  /** Silence reminders in the menu: the options again, then quiet. */
  private fun homeReminder(last: Boolean): String =
      if (last) str(R.string.home_reminder_last) else homePrompt()

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
    showStatus(text)
    reply(text)
  }

  /** Status line plus a spoken note. */
  fun say(text: String) {
    showStatus(text)
    sayAside(text)
  }

  private fun showStatus(text: String) {
    val h = host
    if (h != null) h.onStatus(text) else if (isHome) _homeStatus.value = text
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
      val home = isHome
      val waiting = if (home) true else h?.isWaitingForUser() == true
      if ((!home && h == null) || !quiet() || !waiting) {
        nudge.busy(now)
        continue
      }
      val reminder = nudge.due(now) ?: continue
      val text =
          (if (home) homeReminder(nudge.isLast(reminder))
          else h?.reminder(reminder, nudge.isLast(reminder))) ?: continue
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
      val texts = host?.texts()
      if (texts == null && !isHome) return@launch
      val now = SystemClock.elapsedRealtime()
      when {
        pausedByGlasses -> sayAside(texts?.pausedByGlasses ?: str(R.string.tool_paused_by_glasses))
        now - lastAlertMs > ALERT_EXPLAINS_MS -> sayAside(texts?.streamLost ?: str(R.string.tool_stream_lost))
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
