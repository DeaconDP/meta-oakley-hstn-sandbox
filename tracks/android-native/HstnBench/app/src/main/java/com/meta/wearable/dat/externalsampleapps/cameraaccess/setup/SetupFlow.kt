// SetupFlow - the spoken conversation on the setup screen, as pure logic
//
// The app shows the setup screen until it is registered with the Meta AI app. A blind user can't see
// the one "Connect my glasses" button, so the screen talks: a short welcome, then it listens for
// connect / help / repeat / open settings / quit (SetupGrammar). "Connect" speaks the handoff and
// opens Meta AI. Coming back still unconnected gets "not connected yet, say connect to try again".
// Quiet users get two gentle reminders (IdleNudge), then silence. Lines that need the microphone
// or Bluetooth say how to fix them instead.
//
// SetupVoice (Android) feeds events in and carries out the returned actions: speak a line, then
// listen / open Meta AI / ask for permissions / open settings / quit. Time is passed in so the
// whole conversation is JVM-testable (SetupFlowTest).

package com.meta.wearable.dat.externalsampleapps.cameraaccess.setup

import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.IdleNudge
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.Phrases

/** One Android permission group, as the setup screen sees it. */
enum class PermState {
  GRANTED,
  /** Not granted, and the system dialog can still be shown. */
  ASKABLE,
  /** Not granted and the system won't ask again ("Don't allow" twice): only Settings can fix it. */
  BLOCKED,
}

/** Everything the setup screen says. SetupVoice maps each to a string in strings_setup_voice.xml. */
enum class SetupLine {
  WELCOME,
  WELCOME_NO_MIC,
  WELCOME_NO_BLUETOOTH,
  RESUMED,
  HELP,
  HANDOFF,
  NOT_CONNECTED_YET,
  DIDNT_OPEN,
  DECLINED,
  NOT_UNDERSTOOD,
  REMINDER,
  LAST_REMINDER,
  GOODBYE,
  OPENING_SETTINGS,
  NEEDS_BLUETOOTH_ASK,
  NEEDS_BLUETOOTH_SETTINGS,
  ALREADY_CONNECTING,
  /** Free text (an error message); [SetupAction.Say.text] carries it. */
  TEXT,
}

/** What happens after a line has been spoken. */
enum class Next {
  LISTEN,
  START_REGISTRATION,
  ASK_PERMISSIONS,
  OPEN_SETTINGS,
  QUIT,
}

sealed interface SetupAction {
  data class Say(val line: SetupLine, val then: Next = Next.LISTEN, val text: String? = null) :
      SetupAction
}

class SetupFlow(
    private val nudge: IdleNudge = IdleNudge(listOf(REMINDER_GAP_MS, SECOND_REMINDER_GAP_MS)),
    private val notUnderstoodGapMs: Long = 8_000L,
    private val handoffTimeoutMs: Long = 10_000L,
) {
  companion object {
    const val REMINDER_GAP_MS = 25_000L
    const val SECOND_REMINDER_GAP_MS = 50_000L
    /** Longer than this isn't taken as a failed command ("Sorry?"), just ignored as chatter. */
    const val MAX_NOT_UNDERSTOOD_WORDS = 6
    private val NOT_REPEATABLE =
        setOf(SetupLine.NOT_UNDERSTOOD, SetupLine.REMINDER, SetupLine.LAST_REMINDER, SetupLine.TEXT)
  }

  var bluetooth: PermState = PermState.ASKABLE
    private set
  var mic: PermState = PermState.ASKABLE
    private set

  /** The welcome has been given (this activity). */
  var greeted = false
    private set

  private var lastLine: SetupLine? = null
  private var lastNotUnderstoodMs = Long.MIN_VALUE / 2
  private var handoffAtMs: Long? = null
  private var leftDuringHandoff = false

  /** True between "Opening Meta AI" and coming back (or giving up waiting for Meta AI to open). */
  val isHandingOff: Boolean
    get() = handoffAtMs != null

  fun permissions(bluetooth: PermState, mic: PermState) {
    this.bluetooth = bluetooth
    this.mic = mic
  }

  /** The screen is showing, permissions are known and registration has settled as "not yet". */
  fun ready(nowMs: Long): List<SetupAction> {
    greeted = true
    nudge.userActed(nowMs)
    val line =
        when {
          bluetooth != PermState.GRANTED -> SetupLine.WELCOME_NO_BLUETOOTH
          mic != PermState.GRANTED -> SetupLine.WELCOME_NO_MIC
          else -> SetupLine.WELCOME
        }
    return say(line)
  }

  /** The app came back to the foreground, still not registered (after the settle delay). */
  fun returned(nowMs: Long): List<SetupAction> {
    nudge.userActed(nowMs)
    if (!greeted) return ready(nowMs)
    val wasHandingOff = handoffAtMs != null
    handoffAtMs = null
    leftDuringHandoff = false
    return when {
      wasHandingOff -> say(SetupLine.NOT_CONNECTED_YET)
      bluetooth != PermState.GRANTED -> say(SetupLine.WELCOME_NO_BLUETOOTH)
      mic != PermState.GRANTED -> say(SetupLine.WELCOME_NO_MIC)
      else -> say(SetupLine.RESUMED)
    }
  }

  /** The activity stopped (Meta AI or Settings opened, or the user left). */
  fun leftApp() {
    if (handoffAtMs != null) leftDuringHandoff = true
  }

  /** Registration was started (by voice, or by the button). */
  fun registrationStarted(nowMs: Long) {
    handoffAtMs = nowMs
    leftDuringHandoff = false
  }

  /** A final transcript from the recogniser. */
  fun heard(transcript: String, nowMs: Long): List<SetupAction> {
    val command = SetupGrammar.parse(transcript)
    if (command == null) {
      val words = Phrases.wordCount(transcript)
      if (words == 0 || words > MAX_NOT_UNDERSTOOD_WORDS) return emptyList()
      if (nowMs - lastNotUnderstoodMs < notUnderstoodGapMs) return emptyList()
      lastNotUnderstoodMs = nowMs
      nudge.userActed(nowMs)
      return say(SetupLine.NOT_UNDERSTOOD)
    }
    nudge.userActed(nowMs)
    return when (command) {
      SetupCommand.CONNECT -> connect()
      SetupCommand.HELP -> say(SetupLine.HELP)
      SetupCommand.REPEAT -> say(lastLine ?: SetupLine.WELCOME)
      SetupCommand.OPEN_SETTINGS -> say(SetupLine.OPENING_SETTINGS, Next.OPEN_SETTINGS)
      SetupCommand.QUIT -> say(SetupLine.GOODBYE, Next.QUIT)
      SetupCommand.DECLINE -> say(SetupLine.DECLINED)
    }
  }

  private fun connect(): List<SetupAction> =
      when {
        handoffAtMs != null -> say(SetupLine.ALREADY_CONNECTING)
        bluetooth == PermState.ASKABLE -> say(SetupLine.NEEDS_BLUETOOTH_ASK, Next.ASK_PERMISSIONS)
        bluetooth == PermState.BLOCKED -> say(SetupLine.NEEDS_BLUETOOTH_SETTINGS)
        else -> say(SetupLine.HANDOFF, Next.START_REGISTRATION)
      }

  /**
   * Call about once a second while the screen is showing. [busy] = speaking or not able to hear
   * (no reminders then). Returns a reminder, or "Meta AI didn't open", when due.
   */
  fun tick(nowMs: Long, busy: Boolean): List<SetupAction> {
    val started = handoffAtMs
    if (started != null && !leftDuringHandoff && nowMs - started > handoffTimeoutMs) {
      handoffAtMs = null
      nudge.userActed(nowMs)
      return say(SetupLine.DIDNT_OPEN)
    }
    if (busy || !greeted || started != null || mic != PermState.GRANTED) {
      nudge.busy(nowMs)
      return emptyList()
    }
    val due = nudge.due(nowMs) ?: return emptyList()
    return say(if (nudge.isLast(due)) SetupLine.LAST_REMINDER else SetupLine.REMINDER)
  }

  /** An error to speak (the snackbar's text), then carry on listening. */
  fun error(text: String): List<SetupAction> = listOf(SetupAction.Say(SetupLine.TEXT, Next.LISTEN, text))

  private fun say(line: SetupLine, then: Next = Next.LISTEN): List<SetupAction> {
    if (line !in NOT_REPEATABLE) lastLine = line
    return listOf(SetupAction.Say(line, then))
  }
}
