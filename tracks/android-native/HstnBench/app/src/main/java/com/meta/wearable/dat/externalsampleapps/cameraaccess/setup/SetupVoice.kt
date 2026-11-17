// SetupVoice - the setup screen talks and listens, so a blind user never needs the button
//
// Activity-scoped ViewModel (MainActivity `by viewModels()`, the composables `viewModel()`). It
// runs SetupFlow's conversation with a ToolSpeaker (accessibility audio) and the phone's speech
// recogniser (PhoneSpeechInput, on-device when the phone has one). There's no glasses session before
// registration, so the glasses' recogniser can't be used here.
//
// Lifecycle:
//   - HomeScreen attaches while it shows (app not registered) and passes the Host (MainActivity),
//     and reports start/stop of the activity.
//   - MainActivity reports the permission state after its launch check, and uses [speakThen] to say
//     what Android's permission dialog is about before it opens.
//   - When registration succeeds HomeScreen leaves the composition and detaches: the mic and TTS
//     are released so the registered screen's own voice mode can take over cleanly.
// The mic is stopped while this speaks (so it never hears itself) and while the app is in the
// background.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.setup

import android.app.Application
import android.os.SystemClock
import android.util.Log
import androidx.annotation.StringRes
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.meta.wearable.dat.externalsampleapps.cameraaccess.R
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.PhoneSpeechInput
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolSpeaker
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.VoiceState
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

class SetupVoice(application: Application) : AndroidViewModel(application), ToolSpeaker.Listener {

  /** What the setup conversation asks the activity to do. */
  interface Host {
    fun startRegistration()

    fun quitApp()

    fun openAppSettings()

    /** Ask for the launch permissions again (the user said "connect" with Nearby devices off). */
    fun askAppPermissions()
  }

  data class Ui(
      val speaking: Boolean = false,
      val listening: Boolean = false,
      val micGranted: Boolean = false,
      val heard: String? = null,
      val said: String? = null,
  )

  private val _ui = MutableStateFlow(Ui())
  val ui: StateFlow<Ui> = _ui.asStateFlow()

  private val flow = SetupFlow()
  private var speaker: ToolSpeaker? = null
  private var voice: PhoneSpeechInput? = null
  private val voiceJobs = mutableListOf<Job>()
  private var host: Host? = null
  private var foreground = false
  private var permissionsKnown = false
  private var cameBack = false
  private var greetJob: Job? = null
  private var tickJob: Job? = null
  private var watchdog: Job? = null
  private var launchedTool: String? = null

  // Speech in progress: only the latest utterance's continuation runs.
  private var sequence = 0
  private var currentTag: String? = null
  private var afterSpeech: (() -> Unit)? = null
  private val spoken = ArrayDeque<String>()

  private val app: Application
    get() = getApplication()

  // MARK: - Inputs

  fun attach(host: Host) {
    this.host = host
    maybeGreet()
    startTicking()
  }

  /** Not showing any more (registered, or the activity is going away): release mic and TTS. */
  fun detach() {
    host = null
    greetJob?.cancel()
    tickJob?.cancel()
    stopListening()
    releaseSpeaker()
    _ui.update { it.copy(speaking = false, listening = false) }
  }

  fun setForeground(on: Boolean) {
    if (foreground == on) return
    foreground = on
    if (on) {
      maybeGreet()
      startTicking()
    } else {
      greetJob?.cancel()
      tickJob?.cancel()
      if (flow.greeted) cameBack = true
      flow.leftApp()
      stopListening()
      speaker?.stop()
      currentTag = null
      afterSpeech = null
      _ui.update { it.copy(speaking = false) }
    }
  }

  /** Launched voice-first into a tool ("open Mail Reader") before setup: the welcome names it. */
  fun setLaunchedTool(name: String?) {
    launchedTool = name
  }

  /** From MainActivity after each launch permission check. */
  fun onPermissions(bluetooth: PermState, mic: PermState) {
    val micWasGranted = flow.mic == PermState.GRANTED
    flow.permissions(bluetooth, mic)
    permissionsKnown = true
    _ui.update { it.copy(micGranted = mic == PermState.GRANTED) }
    if (mic != PermState.GRANTED) stopListening()
    else if (!micWasGranted && flow.greeted && currentTag == null) startListening()
    maybeGreet()
  }

  /** Speaks [text] (an explanation before a system dialog), then runs [then]. */
  fun speakThen(text: String, then: () -> Unit) {
    speak(text) {
      then()
      if (host == null) releaseSpeaker()
    }
  }

  /** A final transcript: from the recogniser, or from a test. */
  fun hear(text: String) {
    Log.i(TAG, "heard \"$text\"")
    _ui.update { it.copy(heard = text) }
    if (host == null) return
    run(flow.heard(text, now()))
  }

  /** The Connect button was pressed (TalkBack or sighted help): register now, no speech first. */
  fun connectTapped() {
    stopSpeaking()
    flow.registrationStarted(now())
  }

  /**
   * Speaks an error (the snackbar text). On the setup screen the conversation pauses the mic for it
   * and carries on listening; elsewhere it's spoken and the TTS released. The Nearby devices error
   * is skipped here because the setup conversation already says it.
   */
  fun announce(text: String) {
    if (text == app.getString(R.string.setup_bluetooth_denied)) return
    if (host != null) run(flow.error(text))
    else speak(text) { if (host == null) releaseSpeaker() }
  }

  /** Everything sent to speech, newest last (tests can't hear). */
  fun recentSpeech(): List<String> = synchronized(spoken) { spoken.toList() }

  // MARK: - Conversation

  private fun maybeGreet() {
    if (host == null || !foreground || !permissionsKnown) return
    if (flow.greeted && !cameBack) return
    if (greetJob?.isActive == true) return
    greetJob =
        viewModelScope.launch {
          // Registration state arrives a moment after Wearables.initialize; a registered user
          // shouldn't hear the welcome start. If it flips, HomeScreen detaches and this is cancelled.
          delay(SETTLE_MS)
          val back = cameBack
          cameBack = false
          run(if (back) flow.returned(now()) else flow.ready(now()))
        }
  }

  private fun startTicking() {
    if (host == null || !foreground || tickJob?.isActive == true) return
    tickJob =
        viewModelScope.launch {
          while (isActive) {
            delay(TICK_MS)
            val busy = currentTag != null || voice?.state?.value != VoiceState.LISTENING
            run(flow.tick(now(), busy))
          }
        }
  }

  private fun run(actions: List<SetupAction>) {
    for (action in actions) {
      when (action) {
        is SetupAction.Say -> speak(textFor(action)) { carryOut(action.then) }
      }
    }
  }

  private fun carryOut(next: Next) {
    val h = host ?: return
    when (next) {
      Next.LISTEN -> startListening()
      Next.START_REGISTRATION -> {
        flow.registrationStarted(now())
        h.startRegistration()
      }
      Next.ASK_PERMISSIONS -> h.askAppPermissions()
      Next.OPEN_SETTINGS -> h.openAppSettings()
      Next.QUIT -> h.quitApp()
    }
  }

  private fun textFor(say: SetupAction.Say): String {
    if (say.line == SetupLine.TEXT) return say.text.orEmpty()
    val text = app.getString(resFor(say.line))
    val tool = launchedTool
    val isWelcome =
        say.line == SetupLine.WELCOME ||
            say.line == SetupLine.WELCOME_NO_MIC ||
            say.line == SetupLine.WELCOME_NO_BLUETOOTH
    return if (isWelcome && tool != null) app.getString(R.string.setup_tool_first, tool) + " " + text
    else text
  }

  @StringRes
  private fun resFor(line: SetupLine): Int =
      when (line) {
        SetupLine.WELCOME -> R.string.setup_welcome
        SetupLine.WELCOME_NO_MIC -> R.string.setup_welcome_no_mic
        SetupLine.WELCOME_NO_BLUETOOTH -> R.string.setup_welcome_no_bluetooth
        SetupLine.RESUMED -> R.string.setup_resumed
        SetupLine.HELP -> R.string.setup_help
        SetupLine.HANDOFF -> R.string.setup_handoff
        SetupLine.NOT_CONNECTED_YET -> R.string.setup_not_connected_yet
        SetupLine.DIDNT_OPEN -> R.string.setup_didnt_open
        SetupLine.DECLINED -> R.string.setup_declined
        SetupLine.NOT_UNDERSTOOD -> R.string.setup_not_understood
        SetupLine.REMINDER -> R.string.setup_reminder
        SetupLine.LAST_REMINDER -> R.string.setup_last_reminder
        SetupLine.GOODBYE -> R.string.setup_goodbye
        SetupLine.OPENING_SETTINGS -> R.string.setup_opening_settings
        SetupLine.NEEDS_BLUETOOTH_ASK -> R.string.setup_needs_bluetooth_ask
        SetupLine.NEEDS_BLUETOOTH_SETTINGS -> R.string.setup_needs_bluetooth_settings
        SetupLine.ALREADY_CONNECTING -> R.string.setup_already_connecting
        SetupLine.TEXT -> R.string.setup_status_off // not used: TEXT carries its own text
      }

  // MARK: - Speech

  private fun speak(text: String, then: () -> Unit) {
    stopListening()
    val s = speaker ?: ToolSpeaker(app, this).also { speaker = it }
    s.stop()
    val tag = "setup${++sequence}"
    currentTag = tag
    afterSpeech = then
    synchronized(spoken) {
      spoken.addLast(text)
      while (spoken.size > MAX_SPOKEN) spoken.removeFirst()
    }
    Log.i(TAG, "say \"$text\"")
    _ui.update { it.copy(speaking = true, said = text) }
    s.speak(text, tag)
    // If the engine never reports the end, carry on anyway (a permission dialog must still open).
    watchdog?.cancel()
    watchdog =
        viewModelScope.launch {
          delay(WATCHDOG_BASE_MS + text.length * WATCHDOG_PER_CHAR_MS)
          if (currentTag == tag) {
            Log.w(TAG, "speech end not reported; carrying on")
            onSpoken(tag)
          }
        }
  }

  private fun stopSpeaking() {
    speaker?.stop()
    currentTag = null
    afterSpeech = null
    watchdog?.cancel()
    _ui.update { it.copy(speaking = false) }
  }

  override fun onSpoken(tag: String) {
    if (tag != currentTag) return
    currentTag = null
    watchdog?.cancel()
    _ui.update { it.copy(speaking = false) }
    val then = afterSpeech
    afterSpeech = null
    then?.invoke()
  }

  override fun onEngineState(available: Boolean) {
    if (!available) Log.w(TAG, "text to speech unavailable")
  }

  private fun releaseSpeaker() {
    watchdog?.cancel()
    currentTag = null
    afterSpeech = null
    speaker?.shutdown()
    speaker = null
  }

  // MARK: - Listening

  private fun startListening() {
    if (host == null || !foreground || flow.mic != PermState.GRANTED || currentTag != null) return
    val v = voice ?: PhoneSpeechInput(app, viewModelScope).also { created ->
      voice = created
      voiceJobs +=
          viewModelScope.launch {
            created.utterances.collect { u -> if (u.isFinal && voice === created) hear(u.text) }
          }
      voiceJobs +=
          viewModelScope.launch {
            created.state.collect { st -> _ui.update { it.copy(listening = st == VoiceState.LISTENING) } }
          }
    }
    v.start()
  }

  private fun stopListening() {
    val v = voice ?: return
    voice = null
    v.stop()
    voiceJobs.forEach { it.cancel() }
    voiceJobs.clear()
    _ui.update { it.copy(listening = false) }
  }

  override fun onCleared() {
    detach()
    super.onCleared()
  }

  private fun now(): Long = SystemClock.elapsedRealtime()

  private companion object {
    const val TAG = "SetupVoice"
    const val SETTLE_MS = 2_500L
    const val TICK_MS = 1_000L
    const val MAX_SPOKEN = 50
    const val WATCHDOG_BASE_MS = 4_000L
    const val WATCHDOG_PER_CHAR_MS = 90L
  }
}
