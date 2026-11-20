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
//   settings   "Make it your own" (notes/customisation-android.md): the SettingsStore drives the
//              speaker, earcons, tones and reminders; SettingsGrammar runs after the tool's grammar
//              (first, while trying voices or answering a question); shortcuts are rewritten
//              before anything; conversation mode silences speech until "carry on"; glasses
//              controls (Experimental) run mapped commands.
//   home       the home voice menu: with home=true, voice runs for the whole camera screen, not just
//              while a tool is open. With no tool open, transcripts go to GlobalGrammar.parseHome
//              ("read my mail" opens it, "what can I say", "close the app" leaves). "Main menu" in
//              any tool comes back here. See notes/tools-layer.md > Home voice menu.
//   camera     CameraSourceSelector (notes/phone-camera.md): the tools' PageCamera is the phone
//              (PhoneCamera, CameraX) or the glasses (CameraViewModel), switchable at runtime ("use
//              the phone", "use the glasses"). With the phone there is no session, no connect
//              narration, no glasses health and no reconnect loop; the phone's own pitfalls are
//              spoken instead (permission, camera in use, too dark: "torch on").
//   mode       hands-free or toolbox (notes/hands-free-mode.md, HandsFreeStore, HandsFreePolicy).
//              Everything above runs in both, except: in the toolbox the mic is off until
//              [pushToTalk] (one command, same grammar), and there is no start-up narration, no
//              screen-change narration, no silence reminders, no spoken pitfalls with no tool open,
//              and no automatic reconnecting at home. A tool launched straight in (alias, deep
//              link, extra) is a voice-first visit and behaves as hands-free until the app is left.
//   surface    HandsFreeSurface: the card (screen, state line, last heard, hints) for the phone
//              screen and, in hands-free mode, a glasses display (GlassesDisplaySink). Tools publish
//              through [say]/[warn] (the state line) and [publishCard]; never the display API.
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
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.AudioMath
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.SettingsCommand
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.SettingsEnv
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.SettingsPrefs
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.SettingsStore
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.SettingsVoice
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.Setup
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.SetupSpeech
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.Shortcuts
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.VoiceChoice
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.Words
import java.util.Locale
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.GlassesCard
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.HandsFreePolicy
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.HandsFreeRules
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ModeChange
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.Verbosity
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.CameraSource
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.DarkWatch
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.PhoneCameraWording
import com.meta.wearable.dat.externalsampleapps.cameraaccess.setup.PermState
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
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

@OptIn(ExperimentalCoroutinesApi::class)
class ToolHub(
    application: Application,
    /** The glasses camera (CameraViewModel, also the GlassesLink). */
    glasses: PageCamera,
    /** Registered with Meta AI when the screen opened (AUTO picks the glasses then). */
    initiallyRegistered: Boolean = true,
) : AndroidViewModel(application), ToolSpeaker.Listener {

  companion object {
    private const val TAG = "ToolHub"
    private const val MACRO_STEP_WAIT_MS = 8_000L
    private const val LINK_WAIT_MS = 20_000L
    /** The phone camera opens in well under a second; this covers a slow first bind. */
    private const val PHONE_WAIT_MS = 6_000L
    /** After a camera switch, the old camera stopping isn't a lost stream. */
    private const val SWITCH_GRACE_MS = 8_000L
    /** Placeholder glasses reading while on the phone (glasses alerts are dropped then). */
    private val NO_GLASSES = GlassesSnapshot(paired = true, connected = false)
    private const val SORRY_GAP_MS = 8_000L
    private const val SORRY_MAX_WORDS = 6
    private const val STREAM_LOST_SAY_DELAY_MS = 1_500L
    private const val ALERT_EXPLAINS_MS = 4_000L
    private const val RECONNECT_EVERY_MS = 4_000L
    private const val NUDGE_CHECK_MS = 1_000L
    private const val SPOKEN_LOG_SIZE = 50
    /** Push to talk: how long to wait for the one command. */
    private const val PUSH_TO_TALK_MS = 8_000L
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

  /** Every "Make it your own" setting (shared with the book reader and the settings screen). */
  val settings: SettingsStore = SettingsPrefs.store(application)
  private val settingsPrefs = SettingsPrefs.prefs(application)

  /** The saved mode and the settings hands-free can change by voice. */
  val mode: HandsFreeStore = HandsFreeStore.get(application)

  // MARK: - Cameras (notes/phone-camera.md)

  private val registered = MutableStateFlow(initiallyRegistered)

  /** The phone's back camera (CameraX). The camera screen attaches its lifecycle and preview. */
  val phoneCamera = PhoneCamera(application, viewModelScope)

  /** Which camera the tools use, and the switch between them. */
  val sources =
      CameraSourceSelector(
          scope = viewModelScope,
          glasses = glasses,
          phone = phoneCamera,
          setting =
              mode.settings
                  .map { it.cameraSource }
                  .stateIn(viewModelScope, SharingStarted.Eagerly, mode.settings.value.cameraSource),
          registered = registered,
      )

  /** The tools' camera: whichever source is in use. */
  val camera: PageCamera = sources

  private val glassesLink: GlassesLink? = sources.glassesLink

  /** The camera in use. */
  val cameraSource: StateFlow<CameraSource> = sources.source

  /**
   * Set by the camera screen: asks Android for the camera permission (after ToolHub said why, in
   * hands-free mode). Returns GRANTED, ASKABLE (refused) or BLOCKED (Android won't ask again).
   */
  var requestCameraPermission: (suspend () -> PermState)? = null

  /** Set by the camera screen: start Meta AI registration ("connect my glasses" before setup). */
  var onConnectGlasses: (() -> Unit)? = null

  private val darkWatch = DarkWatch()
  private var switchedAtMs = 0L

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
  private var nudgeGaps = settings.current.tips.reminderGapsMs()
  private var nudge = IdleNudge(nudgeGaps)
  private val watch = GlassesWatch(application)
  private val health = HealthMonitor()

  /** Which microphone voice control is using. */
  val microphone: StateFlow<Microphone> = voice.microphone

  /** Phone screen mirror and glasses display (in hands-free mode, when the glasses have one). */
  val surface = HandsFreeSurface(viewModelScope)

  private val displaySink =
      GlassesDisplaySink(
          session = { sources.deviceSession },
          wanted = { policy.handsFree && mode.settings.value.glassesDisplay && !sources.usingPhone },
          heardLabel = application.getString(R.string.hf_card_heard),
          // A button on the glasses = saying its phrase.
          onHint = { phrase -> viewModelScope.launch { runCommand(phrase) } },
      )

  private val _pushToTalk = MutableStateFlow(false)
  /** The push-to-talk button is listening for its one command. */
  val pushToTalkActive: StateFlow<Boolean> = _pushToTalk.asStateFlow()

  private val _activeTool = MutableStateFlow<ToolRequest?>(null)
  /** The tool whose screen is showing, or null for the camera screen. */
  val activeTool: StateFlow<ToolRequest?> = _activeTool.asStateFlow()

  /** Latest glasses/phone readings (battery, worn, Bluetooth...), null until the watch reports. */
  var glassesNow: GlassesSnapshot? = null
    private set
  var phoneNow: PhoneSnapshot? = null
    private set

  /**
   * A short note is being spoken or is queued (sayAside); tools reading text wait for it. Counted,
   * not a flag: asides queue behind each other ("Connecting…" then the welcome), and the first one
   * finishing mustn't report quiet while the next is still playing.
   */
  val isSpeakingAside: Boolean
    get() = asidesPending > 0

  private var asidesPending = 0

  /** The stream dropped while a tool was open and hasn't come back yet. */
  var streamLost = false
    private set

  /** The main speech rate (tools without an override of their own). */
  val sharedRate: Float
    get() = settings.current.rateFor(null)

  /** Settings by voice: commands, replies, trying voices, conversation mode. */
  val settingsVoice =
      SettingsVoice(
          settings,
          object : SettingsEnv {
            override fun voices(): List<VoiceChoice> = speaker.voices()

            override fun languageName(): String = speaker.languageName()

            override val controlsAvailable: Boolean
              get() = true
          },
      )

  private val _showSettings = MutableStateFlow(false)
  /** "Open settings" by voice: the camera screen shows the settings screen. */
  val showSettings: StateFlow<Boolean> = _showSettings.asStateFlow()

  fun setShowSettings(show: Boolean) {
    _showSettings.value = show
  }

  /** What the settings screen shows. */
  data class SettingsView(
      val setup: Setup,
      val unkept: Boolean,
      val locked: Boolean,
      val profile: String,
      val profiles: List<String>,
      val canUndo: Boolean,
      val lastChange: String?,
  )

  private fun settingsViewNow() =
      SettingsView(
          settings.current, settings.hasUnkept, settings.locked, settings.activeProfile,
          settings.profiles.keys.toList(), settings.canUndo, settings.lastChange,
      )

  private val _settingsView = MutableStateFlow(settingsViewNow())
  val settingsView: StateFlow<SettingsView> = _settingsView.asStateFlow()

  /** Set by the camera screen: opens the share sheet with the setup ("share my setup"). */
  var onShareSetup: ((json: String, code: String) -> Unit)? = null

  /** The experimental audio bus, while switched on (SettingsPrefs.audioBus). */
  private var bus: AudioBus? = null

  /** Glasses buttons (Experimental), attached while streaming with controls on. */
  private val controls = GlassesControls(viewModelScope) { key -> runControl(key) }
  private var macroJob: Job? = null
  private val settingsListener: (Setup) -> Unit = { applySettings() }

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
  /** Continuous listening (hands-free) and its silence reminders. */
  private var listenJob: Job? = null
  private var nudgeJob: Job? = null
  private var pushJob: Job? = null
  /** This visit is voice-first whatever the saved mode (a tool launched straight in). */
  private var visitVoiceFirst = false
  /** "Disconnect" was said: don't reconnect until "connect". */
  private var userDisconnected = false
  // The card's parts (HandsFreeSurface).
  private var cardState = ""
  private var cardHeard = ""
  private var cardHints: List<String>? = null

  /** What the current mode means (the saved setting, or a voice-first visit). */
  val policy: HandsFreePolicy
    get() = HandsFreeRules.effective(mode.handsFree, visitVoiceFirst)

  /** Hands-free right now: always listening and narrating. */
  val isHandsFree: Boolean
    get() = policy.handsFree

  /** "Short/normal/detailed answers". Tools that can say more or less read this. */
  val verbosity: Verbosity
    get() = Verbosity.valueOf(settings.current.verbosityFor(host?.toolId?.id).name)

  init {
    settings.addListener(settingsListener)
    earcons.speakInstead = { _, word ->
      if (settingsVoice.conversation) false
      else {
        speaker.speak(word, "~earcon")
        true
      }
    }
    applySettings()
    // Glasses controls follow the stream (they need a started session).
    viewModelScope.launch { camera.isStreaming.collect { updateControls() } }
    // A fold or session end stops the stream; the open tool decides whether that matters. With no
    // tool open only hands-free mode reconnects by itself; "disconnect" means stay disconnected.
    viewModelScope.launch {
      camera.isStreaming.drop(1).collect { streaming ->
        val h = host
        if (!streaming && !isRealLoss()) {
          updateCard()
          return@collect
        }
        if (!streaming && !userDisconnected && (h?.onStreamLost() ?: (isHome && policy.reconnectAtHome))) {
          onStreamLost()
        }
        if (streaming && streamLost) onStreamBack()
        updateCard()
      }
    }
    surface.sink = displaySink
    // Display errors are logged by the surface and said once here; speech carries on regardless.
    surface.onSinkError = { if (policy.handsFree) sayAside(str(R.string.hf_display_failed)) }
    viewModelScope.launch { camera.link.collect { updateCard() } }
    viewModelScope.launch { _activeTool.collect { cardState = ""; cardHints = null; updateCard() } }
    viewModelScope.launch { microphone.collect { updateCard() } }
    // The display comes up when it's wanted and the glasses are streaming; goes blank when not.
    viewModelScope.launch {
      var wasWanted = false
      mode.settings.collect { s ->
        val wanted = policy.handsFree && s.glassesDisplay
        if (wanted && !wasWanted) surface.refresh()
        if (!wanted && wasWanted) surface.releaseSink()
        wasWanted = wanted
      }
    }
    viewModelScope.launch { camera.link.drop(1).collect { if (it == CameraLink.STREAMING) surface.refresh() } }
    // A camera switch (voice, settings, AUTO fallback, registration): the old camera stopping isn't
    // a lost stream; the card follows.
    viewModelScope.launch {
      sources.source.drop(1).collect {
        switchedAtMs = SystemClock.elapsedRealtime()
        Log.i(TAG, "camera source=$it")
        updateCard()
      }
    }
    // Phone camera in the dark: suggest the torch once (not in the light tool, which measures it).
    viewModelScope.launch {
      phoneCamera.meanLuma.collect { luma ->
        if (luma < 0f || !sources.usingPhone || host == null || host?.toolId == ToolId.LIGHT ||
            phoneCamera.hasTorch != true || !camera.isStreaming.value) {
          return@collect
        }
        if (darkWatch.update(luma, SystemClock.elapsedRealtime(), phoneCamera.torchOn.value)) {
          Log.i(TAG, "too dark: luma=$luma")
          sayAside(PhoneCameraWording.TOO_DARK)
        }
      }
    }
  }

  /** The app is registered with Meta AI (the camera screen keeps this up to date). */
  fun setRegistered(on: Boolean) {
    registered.value = on
  }

  /**
   * Not streaming any more: does it count as a loss? Not just after a camera switch, and not when
   * the phone camera was stopped on purpose or closed because the app went to the background.
   */
  private fun isRealLoss(): Boolean {
    if (SystemClock.elapsedRealtime() - switchedAtMs < SWITCH_GRACE_MS) return false
    if (sources.usingPhone && (!phoneCamera.wanted || phoneCamera.pausedInBackground)) return false
    return true
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
    if (voiceFirst) visitVoiceFirst = true
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
    // The toolbox shows the menu; only hands-free says it (screen changes are narrated).
    if (policy.narrateStartup) {
      _homeStatus.value = str(R.string.home_back)
      sayFamiliar(str(R.string.home_back), Earcon.SWITCH)
    } else {
      _homeStatus.value = ""
    }
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
    visitVoiceFirst = false
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
    applySettings()
    engineAvailable?.let { tool.onEngineState(it) }
    tool.onAttached(request)
    // The phone camera is cheap to open: have it live behind any tool (the toolbox doesn't start
    // the camera on the home screen).
    if (sources.usingPhone && !camera.isStreaming.value && !userDisconnected && !phoneCamera.wanted) {
      viewModelScope.launch { startPhoneCamera() }
    }
    // Voice already running: this is a switch (or a re-open); the tool talks now. Otherwise
    // openVoice does the welcome first and then calls onOpened.
    if (welcomed) {
      val reason = pendingReason
      if (reason == OpenReason.SWITCHED) {
        tool.texts().welcomeAfterSwitch.takeIf { it.isNotBlank() }?.let { sayAside(it) }
      } else if (policy.narrateStartup) {
        // A tool tapped open in the toolbox doesn't announce itself (its screen does); it still
        // speaks its results.
        sayAside(brief(tool.texts().welcome))
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
   * Starts the runtime while any tool is open (the UI calls it once, not per tool, so switching
   * keeps the mic). [voiceFirst]: launched straight into a tool, so bring the link up without
   * dialogs and narrate each step. [home]: the home menu; this runs for the whole camera screen
   * (until [closeVoice]) and, if no tool is open, in hands-free mode the link comes up the
   * voice-first way and the menu welcomes the user.
   *
   * The mode decides the rest (HandsFreePolicy): hands-free listens all the time and narrates; the
   * toolbox only watches health and links, and listens when [pushToTalk] is pressed. Without the
   * home menu (the touch bench, `--ez home_voice false`) the old behaviour applies: a tool listens
   * while it's open.
   */
  fun openVoice(
      voiceFirst: Boolean,
      requestWearablesPermission: suspend (Permission) -> PermissionStatus,
      requestRecordAudio: suspend () -> Boolean,
      home: Boolean = false,
  ) {
    if (voiceJob?.isActive == true) return
    homeMenu = home
    if (!home) visitVoiceFirst = true
    requestPermission = requestWearablesPermission
    phoneAllowed = requestRecordAudio
    voiceJob = viewModelScope.launch {
      // Everything that can go wrong around the tool is spoken when it changes.
      launch {
        try {
          // On the phone only the phone's own readings matter (battery); no glasses health.
          sources.source
              .flatMapLatest { s -> if (s == CameraSource.PHONE) watch.phone().map { NO_GLASSES to it } else watch.both() }
              .collect { (g, p) ->
                if (!sources.usingPhone) glassesNow = g
                phoneNow = p
                onHealth(health.update(g, p))
              }
        } catch (e: CancellationException) {
          throw e
        } catch (e: Exception) {
          Log.w(TAG, "health watch failed", e)
        }
      }
      // Permission trouble, whoever started the connection. In the toolbox the screen's own
      // "Continue to Meta AI" prompt explains it; a refusal still matters to an open tool.
      launch {
        camera.link.drop(1).collect { link ->
          when (link) {
            CameraLink.NEEDS_PERMISSION ->
                if (policy.replaceDialogs) sayAside(str(R.string.voice_camera_permission))
            // The phone path explains its own refusals (startPhoneCamera, explainPhone).
            CameraLink.CAMERA_DENIED ->
                if ((policy.handsFree || host != null) && !sources.usingPhone) {
                  warn(host?.texts()?.cameraDenied ?: str(R.string.tool_camera_denied))
                }
            else -> Unit
          }
        }
      }
      if (home && _activeTool.value == null) {
        nudge.userActed(SystemClock.elapsedRealtime())
        if (policy.narrateStartup) {
          // Hands-free menu: connect the voice-first way (no dialogs, narrated), then welcome.
          val first = firstRunLine()
          if (!camera.isStreaming.value) {
            first?.let { homeSay(it) }
            bringUpLink(
                requestWearablesPermission,
                connecting = { str(R.string.tool_reconnecting) },
                ready = { host?.texts()?.ready ?: homeWelcome() },
                onReady = { text -> if (host == null) homeSay(text) else sayAside(text) },
            )
          } else {
            homeSay(listOfNotNull(first, homeWelcome()).joinToString(" "))
          }
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
          sayAside(brief(first.texts().welcome))
        }
        host?.let { h -> hostRequest?.let { h.onOpened(it, pendingReason) } }
      }
      welcomed = true
      if (policy.alwaysListening) startListening()
    }
  }

  /** "Hands-free is on. Say hands-free off for touch only." once, on the first run with TalkBack. */
  private fun firstRunLine(): String? =
      if (mode.takeAnnouncement()) str(R.string.hf_first_run) else null

  /**
   * Continuous listening: glasses speech once the session is up (waiting briefly for one), else the
   * phone. Every final transcript goes to [onUtterance]. Plus the silence reminders.
   */
  private fun startListening() {
    if (listenJob?.isActive == true) return
    val rp = requestPermission ?: return
    val phone = phoneAllowed ?: return
    pushJob?.cancel()
    if (policy.idleReminders) nudgeJob = viewModelScope.launch { remindWhenQuiet() }
    listenJob = viewModelScope.launch {
      // Glasses speech rides the session, so wait (briefly) for one before choosing a mic. On the
      // phone camera there's no session to wait for.
      withTimeoutOrNull(LINK_WAIT_MS) {
        combine(sources.source, camera.link) { s, l -> s == CameraSource.PHONE || l >= CameraLink.CONNECTED }
            .first { it }
      }
      val mic =
          voice.start(
              session = sources.deviceSession,
              glassesAllowed = { glassesMicAllowed(rp) },
              phoneAllowed = phone,
          )
      Log.i(TAG, "voice microphone=$mic")
      when (mic) {
        Microphone.GLASSES -> Unit
        // Obvious when the phone is the camera too.
        Microphone.PHONE -> if (!sources.usingPhone) sayAside(str(R.string.voice_using_phone_mic))
        Microphone.NONE -> sayAside(str(R.string.voice_unavailable))
      }
      voice.utterances.collect { onUtterance(it.text, it.isFinal) }
    }
  }

  private fun stopListening() {
    listenJob?.cancel()
    listenJob = null
    nudgeJob?.cancel()
    nudgeJob = null
    voice.stop()
  }

  /** Push to talk has a mic up and is waiting for its command (after the READY earcon). */
  @Volatile
  var pushToTalkReady = false
    private set

  /** Continuous listening is on (hands-free). */
  val isListening: Boolean
    get() = listenJob?.isActive == true

  /**
   * The toolbox's mic button: listen for one command (glasses first, then the phone), run it
   * through the same grammar as hands-free, then turn the mic off. Pressed again while listening, it
   * cancels. In hands-free mode the mic is already on, so it just stops the speech.
   */
  fun pushToTalk() {
    if (isListening) {
      hush()
      return
    }
    if (pushJob?.isActive == true) {
      pushJob?.cancel()
      return
    }
    val rp = requestPermission
    if (rp == null) {
      reply(str(R.string.hf_ptt_not_ready))
      return
    }
    hush()
    nudge.userActed(SystemClock.elapsedRealtime())
    pushJob = viewModelScope.launch {
      _pushToTalk.value = true
      try {
        val mic =
            voice.start(
                session = sources.deviceSession,
                glassesAllowed = { glassesMicAllowed(rp) },
                phoneAllowed = phoneAllowed ?: { false },
            )
        if (mic == Microphone.NONE) {
          voice.stop()
          warn(str(R.string.hf_ptt_no_mic))
          return@launch
        }
        earcons.play(Earcon.READY)
        pushToTalkReady = true
        val heard =
            withTimeoutOrNull(PUSH_TO_TALK_MS) {
              voice.utterances.first { it.isFinal && it.text.isNotBlank() }
            }
        voice.stop()
        pushToTalkReady = false
        _pushToTalk.value = false
        if (heard == null) {
          reply(str(R.string.hf_ptt_nothing))
          return@launch
        }
        Log.i(TAG, "push to talk heard=\"${heard.text}\"")
        runCommand(heard.text)
      } finally {
        pushToTalkReady = false
        // Unless that command turned hands-free on, the mic goes off again.
        if (!isListening) voice.stop()
        _pushToTalk.value = false
      }
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
    pushJob?.cancel()
    requestPermission = null
    phoneAllowed = null
    stopListening()
  }

  val isVoiceOpen: Boolean
    get() = voiceJob?.isActive == true

  /**
   * Brings the camera in use up with no dialogs, then [onReady] with [ready]. Glasses: narrated
   * ("Connecting to your glasses"); if they don't stream within the link wait and the setting is
   * AUTO, "Glasses not connected. Using the phone camera." and the phone takes over. Phone: no
   * connect narration (it opens in under a second); its pitfalls are explained if it can't start.
   */
  private suspend fun bringUpLink(
      requestPermission: (suspend (Permission) -> PermissionStatus)?,
      connecting: () -> String,
      ready: () -> String,
      onReady: (String) -> Unit = { sayAside(it) },
  ) {
    if (sources.usingPhone) {
      bringUpPhone(ready, onReady)
      return
    }
    val link = glassesLink
    if (requestPermission == null || link == null) {
      explainNoGlasses()
      return
    }
    val narration = viewModelScope.launch {
      camera.link.collect { l ->
        if (l == CameraLink.CONNECTING) sayAside(connecting())
      }
    }
    link.connectAndStream(requestPermission)
    val outcome = sources.awaitStreaming(LINK_WAIT_MS)
    narration.cancel()
    if (outcome == CameraSourceSelector.Outcome.UP) {
      earcons.play(Earcon.PAGE_DONE)
      onReady(ready())
    } else if (outcome == CameraSourceSelector.Outcome.FELL_BACK) {
      fellBackToPhone()
      bringUpPhone(ready, onReady)
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

  /** The phone half of [bringUpLink]. */
  private suspend fun bringUpPhone(ready: () -> String, onReady: (String) -> Unit) {
    if (startPhoneCamera() && sources.awaitStreaming(PHONE_WAIT_MS) == CameraSourceSelector.Outcome.UP) {
      earcons.play(Earcon.PAGE_DONE)
      onReady(phoneLine(ready()))
    } else {
      explainPhone()
    }
  }

  /** AUTO gave up on the glasses: end their session attempt and say so. */
  private fun fellBackToPhone() {
    Log.i(TAG, "glasses didn't come up: falling back to the phone camera")
    switchedAtMs = SystemClock.elapsedRealtime()
    glassesLink?.endSession()
    earcons.play(Earcon.SWITCH)
    sayAside(PhoneCameraWording.FELL_BACK)
    restartVoice()
  }

  /** A line written for the glasses ("Your glasses are ready."), said right for the phone. */
  private fun phoneLine(text: String): String =
      if (text.contains("glasses", ignoreCase = true)) PhoneCameraWording.ready(host?.toolId) else text

  /**
   * Starts the phone camera, asking for the permission first if needed (said out loud before
   * Android's dialog in hands-free mode). A permanent refusal isn't asked again: [explainPhone]
   * says how to fix it in Settings. False if it can't start.
   */
  private suspend fun startPhoneCamera(): Boolean {
    if (!phoneCamera.hasPermission()) {
      val ask = requestCameraPermission
      if (ask == null) {
        phoneCamera.reportPermissionRefused(blocked = false)
        return false
      }
      if (policy.replaceDialogs) {
        sayAside(PhoneCameraWording.ASK_PERMISSION)
        awaitQuiet()
      }
      when (ask()) {
        PermState.GRANTED -> Unit
        PermState.BLOCKED -> {
          phoneCamera.reportPermissionRefused(blocked = true)
          return false
        }
        PermState.ASKABLE -> {
          phoneCamera.reportPermissionRefused(blocked = false)
          return false
        }
      }
    }
    darkWatch.reset()
    phoneCamera.start()
    return true
  }

  /** Waits (up to 8 s) for the asides to finish, so a dialog doesn't cover the explanation. */
  private suspend fun awaitQuiet() {
    withTimeoutOrNull(8_000L) { while (isSpeakingAside) delay(100) }
  }

  /** The most specific reason the phone camera isn't streaming, spoken. */
  fun explainPhone() {
    earcons.play(Earcon.ERROR)
    val line = PhoneCameraWording.problem(phoneCamera.problem.value)
    showStatus(line)
    sayAside(line)
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
  fun onUtterance(text: String, isFinal: Boolean) = onUtterance(text, isFinal, fromShortcut = false)

  private fun onUtterance(heard: String, isFinal: Boolean, fromShortcut: Boolean, checkEcho: Boolean = !fromShortcut) {
    val now = SystemClock.elapsedRealtime()
    if (checkEcho && echo.isEcho(heard, now)) {
      if (isFinal) Log.i(TAG, "voice echo ignored: \"$heard\"")
      return
    }
    // Conversation mode: someone is talking to the user. Only "carry on" counts.
    if (settingsVoice.conversation) {
      if (isFinal && settingsVoice.parse(heard) == SettingsCommand.ConversationEnd) {
        nudge.userActed(now)
        runSettings(SettingsCommand.ConversationEnd)
      } else if (isFinal) {
        Log.i(TAG, "conversation mode, ignored: \"$heard\"")
      }
      return
    }
    val text = withoutAddress(heard)
    if (isFinal && !fromShortcut) {
      when (val r = Shortcuts.rewrite(text, settings.current.words)) {
        is Shortcuts.Rewrite.Alias -> {
          Log.i(TAG, "shortcut \"${r.phrase}\" -> \"${r.command}\"")
          if (isHome) _homeHeard.value = text else host?.onHeard(text)
          onUtterance(r.command, true, fromShortcut = true)
          return
        }
        is Shortcuts.Rewrite.Macro -> {
          if (isHome) _homeHeard.value = text else host?.onHeard(text)
          runMacro(r.name, r.steps)
          return
        }
        null -> Unit
      }
    }
    // A settings conversation (trying voices, a yes/no question) takes its short words first.
    if (isFinal) {
      val ctx = settingsVoice.context
      if (ctx.tryingVoices || ctx.question) {
        val cmd = settingsVoice.parse(text)
        if (cmd != null) {
          nudge.userActed(now)
          if (isHome) _homeHeard.value = text else host?.onHeard(text)
          runSettings(cmd)
          return
        }
      }
    }
    dispatch(text, isFinal, now, fromShortcut)
  }

  /**
   * A command that didn't come from the open mic (push to talk, a glasses-display button): the same
   * grammar and handling (shortcuts, conversation mode, settings), without the echo check.
   */
  fun runCommand(text: String) = onUtterance(text, true, fromShortcut = false, checkEcho = false)

  private fun dispatch(text: String, isFinal: Boolean, now: Long, fromShortcut: Boolean) {
    if (isFinal) {
      cardHeard = text
      updateCard()
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
    if (!fromShortcut) h.onHeard(text)
    if (h.onCommand(text)) return
    val settingsCommand = settingsVoice.parse(text)
    if (settingsCommand != null) {
      Log.i(TAG, "voice heard=\"$text\" tool=${h.toolId.id} settings=$settingsCommand")
      runSettings(settingsCommand)
      return
    }
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
    if (handleAnywhere(command)) return
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
        sayFamiliar(str(R.string.voice_paused), Earcon.ACK)
      }
      GlobalCommand.Resume -> reply(brief(h.texts().welcome))
      GlobalCommand.Repeat -> reply(lastSaid ?: h.texts().welcome)
      is GlobalCommand.Faster -> changeRate(h.toolId.id) { it + command.step }
      is GlobalCommand.Slower -> changeRate(h.toolId.id) { it - command.step }
      is GlobalCommand.SetRate -> changeRate(h.toolId.id) { command.rate }
      GlobalCommand.Help ->
          reply(if (hasHomeMenu) h.texts().help + " " + str(R.string.home_help_in_tool) else h.texts().help)
      GlobalCommand.Battery -> reply(batteryReport())
      // "Back" in a tool is "close": up one level.
      GlobalCommand.Close, GlobalCommand.Back -> closeByVoice()
      GlobalCommand.Home -> goHome()
      GlobalCommand.ExitApp -> exitApp()
      else -> Unit
    }
  }

  /**
   * The hands-free commands that mean the same in the menu and in every tool (notes/hands-free-mode.md
   * > What hands-free covers). True if handled.
   */
  private fun handleAnywhere(command: GlobalCommand): Boolean {
    when (command) {
      GlobalCommand.ListTools -> reply(listTools())
      GlobalCommand.WhereAmI -> reply(whereAmI())
      GlobalCommand.Status -> reply(statusReport())
      GlobalCommand.Settings -> reply(settingsReport())
      GlobalCommand.Connect -> connectByVoice()
      GlobalCommand.Disconnect -> disconnectByVoice()
      is GlobalCommand.SetVerbosity -> {
        // One verbosity: the settings store's (applySettings mirrors it into the mode store).
        val r =
            settingsVoice.handle(
                SettingsCommand.SetVerbosity(
                    com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.Verbosity.valueOf(command.verbosity.name),
                ),
                host?.toolId?.id,
            )
        reply(if (settings.locked) r.text else verbosityLine(command.verbosity))
      }
      is GlobalCommand.GlassesDisplay -> setGlassesDisplay(command.on)
      is GlobalCommand.HandsFree -> setHandsFree(command.on)
      is GlobalCommand.UseCamera -> useCamera(command.source)
      GlobalCommand.WhichCamera -> reply(PhoneCameraWording.which(sources.source.value, camera.isStreaming.value))
      is GlobalCommand.Torch -> torch(command.on)
      else -> return false
    }
    return true
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
    val settingsCommand = settingsVoice.parse(text)
    if (settingsCommand != null) {
      Log.i(TAG, "voice heard=\"$text\" tool=home settings=$settingsCommand")
      runSettings(settingsCommand)
      return
    }
    val command = GlobalGrammar.parseHome(text)
    Log.i(TAG, "voice heard=\"$text\" tool=home global=$command")
    if (command != null && handleAnywhere(command)) return
    when (command) {
      null -> sayNotUnderstood(text, busy = false)
      // As if switched to from another tool: earcon, the tool's name, then the tool talks.
      is GlobalCommand.Open -> switchTo(command.request)
      is GlobalCommand.Ask -> ask(command)
      GlobalCommand.Pause -> hush()
      GlobalCommand.Resume, GlobalCommand.Home -> homeReply(homePrompt())
      GlobalCommand.Repeat -> homeReply(lastSaid ?: homePrompt())
      is GlobalCommand.Faster -> changeRate(null) { it + command.step }
      is GlobalCommand.Slower -> changeRate(null) { it - command.step }
      is GlobalCommand.SetRate -> changeRate(null) { command.rate }
      GlobalCommand.Help -> homeReply(str(if (policy.handsFree) R.string.home_help else R.string.hf_help_toolbox))
      GlobalCommand.Battery -> homeReply(batteryReport())
      // Nothing above the menu: "back" says so; "close", "goodbye", "quit" leave the app.
      GlobalCommand.Back -> homeReply(str(R.string.hf_back_at_home))
      GlobalCommand.Close, GlobalCommand.ExitApp -> exitApp()
      else -> Unit
    }
  }

  /** "Main menu. Say read my book, ..." ("Main menu." with short answers; the user's own menu if changed). */
  private fun homePrompt(): String =
      if (verbosity == Verbosity.SHORT) str(R.string.home_back)
      else menuOptions()?.let { getApplication<Application>().getString(R.string.home_prompt_custom, it) } ?: str(R.string.home_prompt)

  /** "SpeakUp is ready. Say read my book, ..." (the user's own menu, if they changed it). */
  private fun homeWelcome(): String =
      if (verbosity == Verbosity.SHORT) str(R.string.hf_welcome_short)
      else menuOptions()?.let { getApplication<Application>().getString(R.string.home_welcome_custom, it) } ?: str(R.string.home_welcome)

  /** "read my mail, labels, light" when the menu was reordered or tools hidden; null for the default. */
  private fun menuOptions(): String? {
    val w = settings.current.words
    if (w.normalisedOrder() == Words.DEFAULT_MENU && w.menuHidden.isEmpty()) return null
    val said =
        mapOf(
            "book" to R.string.home_option_book,
            "mail" to R.string.home_option_mail,
            "labels" to R.string.home_option_labels,
            "watch" to R.string.home_option_watch,
            "light" to R.string.home_option_light,
        )
    return (w.visibleMenu().mapNotNull { id -> said[id]?.let { str(it) } } + str(R.string.home_option_help)).joinToString(", ")
  }

  /** The menu's spoken line, also shown on the camera screen. */
  private fun homeSay(text: String) {
    _homeStatus.value = text
    setCardState(text)
    sayAside(text)
  }

  private fun homeReply(text: String) {
    _homeStatus.value = text
    setCardState(text)
    reply(text)
  }

  /** Silence reminders in the menu: the options again, then quiet. */
  private fun homeReminder(last: Boolean): String =
      if (last) menuOptions()?.let { getApplication<Application>().getString(R.string.home_reminder_last_custom, it) } ?: str(R.string.home_reminder_last)
      else homePrompt()

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

  // MARK: - Hands-free mode

  /**
   * Switches hands-free on or off (the switch, voice, push to talk). Plays the switch earcon and says
   * so in both modes. On: the mic stays on and the screen changes are narrated from now on. Off:
   * the mic goes off (push to talk from now on) and the glasses display goes blank.
   */
  fun setHandsFree(on: Boolean) {
    val change = HandsFreeRules.change(policy.handsFree, on)
    mode.setHandsFree(on)
    if (!on) visitVoiceFirst = false
    Log.i(TAG, "hands-free $change")
    earcons.play(Earcon.SWITCH)
    when (change) {
      ModeChange.TURNED_ON -> {
        reply(str(R.string.hf_turned_on))
        if (isVoiceOpen) {
          // As if the app had opened hands-free: in the menu the glasses come up, narrated.
          val rp = requestPermission
          if (rp != null && _activeTool.value == null && !camera.isStreaming.value && !userDisconnected) {
            viewModelScope.launch {
              bringUpLink(rp, connecting = { str(R.string.tool_reconnecting) }, ready = { homeWelcome() }, onReady = { homeSay(it) })
            }
          }
          startListening()
        }
      }
      ModeChange.TURNED_OFF -> {
        stopListening()
        reply(str(R.string.hf_turned_off))
      }
      ModeChange.ALREADY_ON -> reply(str(R.string.hf_already_on))
      ModeChange.ALREADY_OFF -> reply(str(R.string.hf_already_off))
    }
    if (_activeTool.value == null) _homeStatus.value = lastSaid.orEmpty()
  }

  /** "Glasses display on/off" (voice or the settings switch). */
  fun setGlassesDisplay(on: Boolean) {
    mode.setGlassesDisplay(on)
    earcons.play(Earcon.SWITCH)
    reply(
        str(
            when {
              !on -> R.string.hf_display_off
              !displaySink.supported() -> R.string.hf_display_none
              !policy.handsFree -> R.string.hf_display_on_toolbox
              else -> R.string.hf_display_on
            },
        ),
    )
  }

  /** "There are five tools: ..." */
  fun listTools(): String {
    val names = ToolRegistry.all.map { toolName(it.id) }
    val list = (names.dropLast(1).joinToString(", ") + " " + str(R.string.hf_and) + " " + names.last()).lowercase()
    val app = getApplication<Application>()
    return app.getString(R.string.hf_tools_list, names.size, list) + " " +
        str(if (policy.handsFree) R.string.hf_tools_say else R.string.hf_tools_tap)
  }

  /** "You're in the mail reader. Glasses connected, camera on. Hands-free is on." */
  fun whereAmI(): String {
    val app = getApplication<Application>()
    val tool = _activeTool.value
    val where =
        if (tool == null) str(R.string.hf_where_home)
        else app.getString(R.string.hf_where_tool, toolName(tool.tool).lowercase())
    return listOf(
            where,
            connectionLine(),
            str(if (policy.handsFree) R.string.hf_mode_hands_free else R.string.hf_mode_toolbox),
        )
        .joinToString(" ")
  }

  /** "Glasses connected, camera on. Listening through your glasses. <battery>" */
  fun statusReport(): String {
    val mic =
        when (microphone.value) {
          Microphone.GLASSES -> str(R.string.voice_mic_glasses) + "."
          Microphone.PHONE -> str(R.string.voice_mic_phone) + "."
          Microphone.NONE -> if (policy.handsFree) str(R.string.voice_mic_none) + "." else ""
        }
    return listOf(connectionLine(), mic, batteryReport()).filter { it.isNotEmpty() }.joinToString(" ")
  }

  /** "1.25 times speed. Normal answers. Glasses display on. Hands-free is on." */
  fun settingsReport(): String {
    val app = getApplication<Application>()
    val s = mode.settings.value
    return listOf(
            app.getString(R.string.voice_rate, formatRate(sharedRate)),
            verbosityLine(s.verbosity),
            PhoneCameraWording.setting(s.cameraSource, sources.source.value),
            str(if (s.glassesDisplay) R.string.hf_setting_display_on else R.string.hf_setting_display_off),
            str(if (policy.handsFree) R.string.hf_mode_hands_free else R.string.hf_mode_toolbox),
        )
        .joinToString(" ")
  }

  // MARK: - Camera source (notes/phone-camera.md)

  /**
   * "Use the phone" / "use the glasses" (or the screen's camera switch): stop the old camera, say
   * which one is in use, and bring the new one up if anything was using the old one (a tool open,
   * hands-free, or it was streaming), or always for the phone. Tools collecting frames carry on
   * with the new camera.
   */
  fun useCamera(target: CameraSource) {
    val now = sources.source.value
    if (target == CameraSource.GLASSES && !registered.value) {
      warn(PhoneCameraWording.GLASSES_NOT_SET_UP)
      return
    }
    userDisconnected = false
    if (now == target) {
      reply(if (target == CameraSource.PHONE) PhoneCameraWording.ALREADY_PHONE else PhoneCameraWording.ALREADY_GLASSES)
      if (!camera.isStreaming.value && (host != null || policy.handsFree || target == CameraSource.PHONE)) {
        viewModelScope.launch { bringUpLink(requestPermission, { str(R.string.tool_reconnecting) }, { cameraOnLine() }) }
      }
      return
    }
    val wasActive = camera.isStreaming.value || host != null || policy.handsFree
    Log.i(TAG, "use camera $now -> $target (active=$wasActive)")
    earcons.play(Earcon.SWITCH)
    hush()
    switchedAtMs = SystemClock.elapsedRealtime()
    streamLost = false
    reconnectLoop?.cancel()
    reconnectJob?.cancel()
    if (now == CameraSource.PHONE) {
      phoneCamera.stop()
    } else {
      surface.releaseSink()
      glassesLink?.endSession()
    }
    sources.use(target)
    sayAside(if (target == CameraSource.PHONE) PhoneCameraWording.USING_PHONE else PhoneCameraWording.USING_GLASSES)
    restartVoice()
    if (wasActive || target == CameraSource.PHONE) {
      viewModelScope.launch {
        bringUpLink(
            requestPermission,
            connecting = { str(R.string.tool_reconnecting) },
            ready = { cameraOnLine() },
            onReady = { text ->
              sayAside(text)
              restartVoice()
            },
        )
      }
    }
  }

  private fun cameraOnLine(): String =
      if (sources.usingPhone) PhoneCameraWording.CAMERA_ON else str(R.string.hf_connected)

  /** "Torch on/off": the phone camera's light. */
  fun torch(on: Boolean) {
    if (!sources.usingPhone) {
      reply(PhoneCameraWording.TORCH_GLASSES)
      return
    }
    if (!camera.isStreaming.value) {
      reply(PhoneCameraWording.problem(phoneCamera.problem.value))
      return
    }
    if (!phoneCamera.setTorch(on)) {
      reply(PhoneCameraWording.NO_TORCH)
      return
    }
    reply(if (on) PhoneCameraWording.TORCH_ON else PhoneCameraWording.TORCH_OFF)
  }

  /** The toolbox's "Turn on camera" with the phone in use: start it, explaining only on failure. */
  fun turnOnPhoneCamera() {
    userDisconnected = false
    viewModelScope.launch { if (!startPhoneCamera()) explainPhone() }
  }

  /** "Connect my glasses" before setup: say what happens, then open Meta AI. */
  fun startGlassesSetup() {
    val go = onConnectGlasses
    if (go == null) {
      reply(PhoneCameraWording.GLASSES_NOT_SET_UP)
      return
    }
    reply(PhoneCameraWording.OPENING_META_AI)
    viewModelScope.launch {
      awaitQuiet()
      go()
    }
  }

  private fun verbosityLine(v: Verbosity): String =
      str(
          when (v) {
            Verbosity.SHORT -> R.string.hf_verbosity_short
            Verbosity.NORMAL -> R.string.hf_verbosity_normal
            Verbosity.DETAILED -> R.string.hf_verbosity_detailed
          },
      )

  /** One sentence about the glasses link. */
  private fun connectionLine(): String {
    if (sources.usingPhone) {
      return if (userDisconnected && !camera.isStreaming.value) PhoneCameraWording.CAMERA_OFF
      else PhoneCameraWording.connection(camera.isStreaming.value)
    }
    val g = glassesNow
    return str(
        when {
          userDisconnected && !camera.isStreaming.value -> R.string.hf_link_disconnected_by_user
          camera.isStreaming.value -> R.string.hf_link_streaming
          camera.link.value == CameraLink.CONNECTING || camera.link.value == CameraLink.STARTING_STREAM ->
              R.string.hf_link_connecting
          camera.link.value >= CameraLink.CONNECTED -> R.string.hf_link_connected
          phoneNow?.bluetoothOn == false -> R.string.health_bluetooth_off
          g?.connected == true -> R.string.hf_link_connected
          else -> R.string.hf_link_none
        },
    )
  }

  /** "Connect": bring the session and camera up, narrated, no dialogs. */
  private fun connectByVoice() {
    userDisconnected = false
    if (sources.usingPhone) {
      when {
        !camera.isStreaming.value -> {
          earcons.play(Earcon.ACK)
          hush()
          viewModelScope.launch { bringUpLink(null, { "" }, { PhoneCameraWording.CAMERA_ON }) }
        }
        // The phone camera is already on: "connect" now means the glasses.
        !registered.value -> startGlassesSetup()
        else -> reply(PhoneCameraWording.PHONE_ON_SAY_GLASSES)
      }
      return
    }
    if (camera.isStreaming.value) {
      reply(str(R.string.hf_already_connected))
      return
    }
    val rp = requestPermission
    if (rp == null) {
      reply(str(R.string.hf_ptt_not_ready))
      return
    }
    earcons.play(Earcon.ACK)
    hush()
    viewModelScope.launch {
      bringUpLink(rp, connecting = { str(R.string.tool_reconnecting) }, ready = { str(R.string.hf_connected) })
    }
  }

  /** "Disconnect": end the glasses session (the app stays registered with Meta AI). */
  private fun disconnectByVoice() {
    if (sources.usingPhone) {
      if (!phoneCamera.wanted && !camera.isStreaming.value) {
        reply(PhoneCameraWording.ALREADY_OFF)
        return
      }
      userDisconnected = true
      streamLost = false
      phoneCamera.stop()
      reply(PhoneCameraWording.CAMERA_OFF)
      return
    }
    if (glassesLink?.deviceSession == null && !camera.isStreaming.value) {
      reply(str(R.string.hf_already_disconnected))
      return
    }
    userDisconnected = true
    streamLost = false
    reconnectLoop?.cancel()
    reconnectJob?.cancel()
    surface.releaseSink()
    glassesLink?.endSession()
    reply(str(R.string.hf_disconnected))
  }

  // MARK: - The card (phone screen mirror, glasses display)

  /**
   * For tools: what the card shows besides the status line. [state] replaces the state line (null
   * keeps it); [hints] are up to three phrases that work now (null = the defaults: help, main menu).
   */
  fun publishCard(state: String? = null, hints: List<String>? = null) {
    state?.let { cardState = it }
    cardHints = hints
    updateCard()
  }

  private fun setCardState(text: String) {
    cardState = text
    updateCard()
  }

  private fun updateCard() {
    val tool = _activeTool.value
    val screen = if (tool == null) str(R.string.hf_card_menu) else toolName(tool.tool)
    val state = cardState.ifEmpty { cardLinkLine() }
    val hints =
        cardHints
            ?: str(if (tool == null) R.string.hf_hints_home else R.string.hf_hints_tool).split('|')
    surface.publish(GlassesCard.of(screen, state, cardHeard, hints))
  }

  private fun cardLinkLine(): String =
      str(
          when {
            !camera.isStreaming.value && sources.usingPhone -> R.string.hf_card_phone_off
            !camera.isStreaming.value && camera.link.value == CameraLink.CONNECTING -> R.string.hf_card_connecting
            !camera.isStreaming.value -> R.string.hf_card_disconnected
            microphone.value != Microphone.NONE -> R.string.hf_card_listening
            else -> R.string.hf_card_ready
          },
      )

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
    remember(text)
    if (settingsVoice.conversation) {
      // Conversation mode: no speech. The tool is paused; nothing waits on this note.
      Log.i(TAG, "conversation mode, not said: \"$text\"")
      return
    }
    asidesPending++
    speaker.speak(text, "aside")
  }

  /**
   * A familiar short line ("Paused.", "Main menu."): with "sounds instead of short replies" on,
   * only [earcon] plays.
   */
  fun sayFamiliar(text: String, earcon: Earcon) {
    val s = settings.current.sounds
    if (s.earconsOnly && s.earcons) {
      remember(text)
      earcons.play(earcon)
      return
    }
    sayAside(text)
  }

  /** Tool content (a sentence of a page). ToolHost.onSpoken([tag]) runs when it finishes. */
  fun speak(text: String, tag: String) {
    require(tag != "aside") { "\"aside\" is reserved for sayAside" }
    remember(text)
    if (settingsVoice.conversation) {
      Log.i(TAG, "conversation mode, not read: \"$text\"")
      return
    }
    speaker.speak(text, tag)
  }

  /** How much the open tool (or the menu) should say: short, normal or detailed. */
  fun verbosity(tool: ToolId? = host?.toolId): com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.Verbosity =
      settings.current.verbosityFor(tool?.id)

  /** [text] cut to its first sentence when the user asked for short replies. */
  fun brief(text: String, tool: ToolId? = host?.toolId): String {
    return if (verbosity(tool) == com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.Verbosity.SHORT) SetupSpeech.firstSentence(text) else text
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
    setCardState(text)
  }

  /** Stops speech now, drops what's queued, and tells the echo guard it ended. */
  fun hush() {
    speaker.stop()
    asidesPending = 0 // stop() drops the queue, so none of them will report done
    echo.finished(SystemClock.elapsedRealtime())
  }

  /** Sets the speech rate now (the tool keeps and persists its own value if it has one). */
  fun setRate(rate: Float) {
    speaker.setRate(rate)
  }

  // MARK: - Make it your own

  /** Pushes the current settings into the speaker, earcons, tones, reminders and controls. */
  fun applySettings() {
    val s = settings.current
    val wantBus = settingsPrefs.audioBus
    if (wantBus && bus == null) bus = AudioBus().takeIf { it.available }
    if (!wantBus && bus != null) {
      bus?.release()
      bus = null
    }
    val b = bus
    speaker.setRate(host?.speechRate() ?: s.rateFor(host?.toolId?.id))
    speaker.configure(
        ToolSpeaker.Config(
            pitch = s.speech.pitch,
            pauseMs = s.speech.pauseMs,
            voice = s.speech.voice,
            locale = s.speech.locale,
            pan = AudioMath.pan(AudioMath.Kind.SPEECH, s.ears),
            clearSpeech = s.ears.clearSpeech,
            bus = b,
        ),
    )
    b?.setClearSpeech(s.ears.clearSpeech)
    val earconGains = AudioMath.gains(AudioMath.Kind.EARCON, s.ears)
    earcons.configure(
        Earcons.Config(
            enabled = s.sounds.earcons,
            volume = s.sounds.volume,
            gains = earconGains,
            speakInstead = s.sounds.speakEarcons,
            bus = b,
        ),
    )
    tones.gains = earconGains
    tones.ears = s.ears
    tones.bus = b
    val gaps = s.tips.reminderGapsMs()
    if (gaps != nudgeGaps) {
      nudgeGaps = gaps
      nudge = IdleNudge(gaps)
      nudge.userActed(SystemClock.elapsedRealtime())
    }
    updateControls()
    // Hands-free's "short answers" and the settings store share one value.
    val v = Verbosity.valueOf(s.speech.verbosity.name)
    if (mode.settings.value.verbosity != v) mode.setVerbosity(v)
    _settingsView.value = settingsViewNow()
  }

  /** Installed voices for the speech language (settings screen). */
  fun voices(): List<VoiceChoice> = speaker.voices()

  /** The experimental audio bus on or off (settings screen). */
  fun setAudioBus(on: Boolean) {
    settingsPrefs.audioBus = on
    applySettings()
  }

  val audioBusOn: Boolean
    get() = settingsPrefs.audioBus

  /** Faster/slower/"1.5 times": the tool's own speed if it has one, else the main speed. */
  fun changeRate(tool: String?, requested: (Float) -> Float) {
    val r = settingsVoice.changeRate(tool, requested = requested)
    if (isHome) homeReply(r.text) else reply(r.text)
  }

  /** A settings command heard: change, then say the new value (or run the effect). */
  fun runSettings(cmd: SettingsCommand) {
    val r = settingsVoice.handle(cmd, host?.toolId?.id)
    when (r.effect) {
      SettingsVoice.Effect.CONVERSATION_START -> {
        // Pause whatever the tool is doing, say the one line, then go quiet.
        val h = host
        if (h == null || !h.onGlobal(GlobalCommand.Pause)) hush()
        hush()
        earcons.play(Earcon.ACK)
        speaker.speak(r.text, "~conversation")
        return
      }
      SettingsVoice.Effect.CONVERSATION_END -> {
        reply(r.text)
        host?.onGlobal(GlobalCommand.Resume)
        return
      }
      SettingsVoice.Effect.SHARE_SETUP -> onShareSetup?.invoke(settings.exportJson(), settings.exportCode())
      SettingsVoice.Effect.OPEN_SETTINGS -> _showSettings.value = true
      null -> Unit
    }
    if (isHome) homeReply(r.text) else reply(r.text)
  }

  /** A change made on the settings screen: saved, and said out loud for the user (helper view). */
  fun changeFromScreen(spoken: String, f: (Setup) -> Setup) {
    val r = settingsVoice.fromScreen(spoken, f)
    sayFromScreen(r.text)
  }

  /** Says [text] for the settings screen (undo, keep, import results), if voice is running. */
  fun sayFromScreen(text: String) {
    if (isVoiceOpen && text.isNotBlank()) {
      hush()
      sayAside(text)
    }
  }

  /** "Sam, read my mail": the user's own address word is dropped like the built-in ones. */
  private fun withoutAddress(text: String): String {
    val word = settings.current.words.address ?: return text
    val m = Regex("^\\W*(?:hey |ok |okay )?${Regex.escape(word)}\\b[\\s,.!]*", RegexOption.IGNORE_CASE).find(text) ?: return text
    val rest = text.substring(m.range.last + 1)
    return rest.ifBlank { text }
  }

  /** A routine: each command in turn, as if said, once the one before has settled. */
  private fun runMacro(name: String, steps: List<String>) {
    macroJob?.cancel()
    Log.i(TAG, "routine \"$name\": $steps")
    earcons.play(Earcon.ACK)
    macroJob =
        viewModelScope.launch {
          for ((i, step) in steps.withIndex()) {
            if (i > 0) {
              // Let a tool switch attach and its first line finish before the next command.
              delay(300)
              withTimeoutOrNull(MACRO_STEP_WAIT_MS) {
                while (isSpeakingAside || (_activeTool.value != null && attached.value?.toolId != _activeTool.value?.tool)) delay(100)
              }
            }
            Log.i(TAG, "routine step ${i + 1}: \"$step\"")
            onUtterance(step, true, fromShortcut = true)
          }
        }
  }

  /** A glasses button or swipe (Experimental): its mapped command, as if said. */
  fun runControl(key: String) {
    val c = settings.current.controls
    if (!c.enabled || !isVoiceOpen) return
    val action = c.actionFor(key) ?: return
    nudge.userActed(SystemClock.elapsedRealtime())
    when (val r = Shortcuts.rewrite(action, settings.current.words)) {
      is Shortcuts.Rewrite.Macro -> runMacro(r.name, r.steps)
      is Shortcuts.Rewrite.Alias -> onUtterance(r.command, true, fromShortcut = true)
      null -> onUtterance(action, true, fromShortcut = true)
    }
  }

  private fun updateControls() {
    val session = sources.deviceSession
    if (settings.current.controls.enabled && camera.isStreaming.value && session != null) controls.attach(session)
    else if (!settings.current.controls.enabled) controls.detach()
  }

  /** A button press or command: acknowledge it, and start silence reminders over. */
  fun userActed() {
    earcons.play(Earcon.ACK)
    nudge.userActed(SystemClock.elapsedRealtime())
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
    // ToolHub's own lines that no tool waits for (conversation mode, earcons said as words).
    if (tag.startsWith("~")) return
    if (tag == "aside") {
      asidesPending = (asidesPending - 1).coerceAtLeast(0)
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
      if (settingsVoice.conversation) continue
      sayAside(brief(text))
    }
  }

  /** Nothing of ToolHub's own going on: not talking, not reconnecting, glasses streaming. */
  private fun quiet(): Boolean =
      !isSpeakingAside && reconnectJob?.isActive != true && !streamLost && camera.isStreaming.value

  // MARK: - Link: lost, back, reconnect

  private fun onStreamLost() {
    earcons.play(Earcon.ERROR)
    streamLost = true
    if (sources.usingPhone) {
      // No reconnect loop: CameraX reopens by itself when the camera is free again.
      viewModelScope.launch {
        delay(STREAM_LOST_SAY_DELAY_MS)
        if (camera.isStreaming.value) return@launch
        if (host == null && !isHome) return@launch
        sayAside(PhoneCameraWording.problem(phoneCamera.problem.value))
      }
      return
    }
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
      while (streamLost && !userDisconnected && voiceJob?.isActive == true) {
        delay(RECONNECT_EVERY_MS)
        if (camera.isStreaming.value) break
        val g = glassesNow
        // Not gated on "worn": after a fold the glasses can keep reporting "off" until used.
        val reachable = g == null || g.connected
        val busy = camera.link.value.let {
          it == CameraLink.CONNECTING || it == CameraLink.STARTING_STREAM ||
              it == CameraLink.NEEDS_PERMISSION || it == CameraLink.CAMERA_DENIED
        }
        if (sources.usingPhone) break
        if (reachable && !busy) requestPermission?.let { glassesLink?.connectAndStream(it) }
      }
    }
  }

  /** The stream came back after a loss: say so, and move voice back onto the glasses. */
  private fun onStreamBack() {
    streamLost = false
    host?.onStreamBack()
    if (voiceJob?.isActive != true) return
    if (host == null && !policy.speakAlertsAtHome) return
    earcons.play(Earcon.PAGE_DONE)
    if (sources.usingPhone) {
      say(PhoneCameraWording.CAMERA_BACK)
      return
    }
    say(host?.texts()?.cameraBack ?: str(R.string.tool_camera_back))
    restartVoice()
  }

  /**
   * Not streaming but the user wants the camera: bring the link up (narrated), then run [then]. If
   * it doesn't come up, say why. Returns false if it can't even try (voice not open, so no way to
   * ask for permission); the tool should then say so itself.
   */
  fun reconnectThen(then: () -> Unit): Boolean {
    if (reconnectJob?.isActive == true) return true
    if (sources.usingPhone) {
      userDisconnected = false
      reconnectJob = viewModelScope.launch {
        if (startPhoneCamera() && sources.awaitStreaming(PHONE_WAIT_MS) == CameraSourceSelector.Outcome.UP) then()
        else explainPhone()
      }
      return true
    }
    val rp = requestPermission ?: return false
    val link = glassesLink ?: return false
    sayAside(host?.texts()?.connecting ?: str(R.string.tool_reconnecting))
    link.connectAndStream(rp)
    reconnectJob = viewModelScope.launch {
      when (sources.awaitStreaming(LINK_WAIT_MS)) {
        CameraSourceSelector.Outcome.UP -> then()
        CameraSourceSelector.Outcome.FELL_BACK -> {
          fellBackToPhone()
          if (startPhoneCamera() && sources.awaitStreaming(PHONE_WAIT_MS) == CameraSourceSelector.Outcome.UP) then()
          else explainPhone()
        }
        CameraSourceSelector.Outcome.DOWN -> explainNoGlasses()
      }
    }
    return true
  }

  /** True while [reconnectThen] is waiting for the link. */
  val isReconnecting: Boolean
    get() = reconnectJob?.isActive == true

  /** The most specific reason the glasses can't be reached, spoken. */
  fun explainNoGlasses() {
    if (sources.usingPhone) {
      explainPhone()
      return
    }
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

  /** Moves the always-on mic to the glasses (session up) or the phone (no session). */
  private fun restartVoice() {
    // Only the always-on mic moves; push to talk picks the glasses next time it's pressed.
    if (!isListening) return
    val rp = requestPermission ?: return
    viewModelScope.launch {
      voice.stop()
      voice.start(
          session = sources.deviceSession,
          glassesAllowed = { glassesMicAllowed(rp) },
          phoneAllowed = phoneAllowed ?: { false },
      )
    }
  }

  // MARK: - Glasses and phone health

  private fun onHealth(alerts: List<HealthAlert>) {
    for (alert in alerts) {
      // On the phone camera only the phone's battery matters.
      if (sources.usingPhone && alert !is HealthAlert.PhoneBattery) continue
      Log.i(TAG, "health=$alert")
      lastAlertMs = SystemClock.elapsedRealtime()
      val override = host?.onHealthAlert(alert)
      val app = getApplication<Application>()
      fun text(@StringRes id: Int) = override ?: str(id)
      // The toolbox with no tool open shows pitfalls on the screen without speaking them.
      val speak = host != null || policy.speakAlertsAtHome
      fun warn(line: String) = if (speak) this.warn(line) else showStatus(line)
      fun say(line: String) = if (speak) this.say(line) else showStatus(line)
      when (alert) {
        HealthAlert.BluetoothOff -> warn(text(R.string.health_bluetooth_off))
        HealthAlert.BluetoothOn -> say(text(R.string.health_bluetooth_on))
        HealthAlert.NoGlassesPaired -> warn(text(R.string.health_no_glasses))
        HealthAlert.GlassesDisconnected -> warn(text(R.string.health_disconnected))
        HealthAlert.GlassesConnected -> {
          say(text(R.string.health_connected))
          // Bring the camera back by itself; onStreamBack says when it's ready. Not after
          // "disconnect", and not in the toolbox's menu (the user connects when they want).
          if (!camera.isStreaming.value && !userDisconnected && (host != null || policy.reconnectAtHome)) {
            requestPermission?.let { glassesLink?.connectAndStream(it) }
          }
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
    val g = glassesNow?.takeIf { it.connected && !sources.usingPhone }?.battery
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
    settings.removeListener(settingsListener)
    controls.detach()
    bus?.release()
    voice.stop()
    phoneCamera.release()
    speaker.shutdown()
    earcons.release()
    tones.release()
  }

  class Factory(
      private val application: Application,
      /** The glasses camera (CameraViewModel). */
      private val camera: PageCamera,
      private val registered: Boolean = true,
  ) : ViewModelProvider.Factory {
    override fun <T : ViewModel> create(modelClass: Class<T>): T {
      if (modelClass.isAssignableFrom(ToolHub::class.java)) {
        @Suppress("UNCHECKED_CAST")
        return ToolHub(application, camera, registered) as T
      }
      throw IllegalArgumentException("Unknown ViewModel class")
    }
  }
}
