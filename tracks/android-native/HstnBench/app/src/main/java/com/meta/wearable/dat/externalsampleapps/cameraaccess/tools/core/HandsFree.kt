// HandsFree - the two ways SpeakUp runs, as pure rules
//
// notes/hands-free-mode.md. By default SpeakUp is a toolbox: a touch app, no always-on mic, no
// start-up narration, no idle reminders; a push-to-talk button listens for one command. Hands-free
// is one persisted setting: when it's on, everything works by voice alone (always listening,
// narrated, no dialogs needed) and the screen is optional.
//
//   HandsFreeRules    first run (TalkBack on -> hands-free starts on, said once), what each mode
//                     does (HandsFreePolicy), and what a switch should say (ModeChange).
//   HandsFreeLaunch   the entry points that open straight into hands-free mode and switch it on:
//                     speakup://handsfree, the "Hands-free" launcher shortcut, `--ez handsfree true`.
//
// HandsFreeStore (Android) persists the settings; ToolHub, SetupVoice, MainActivity and the screens
// ask HandsFreePolicy what to do. Pure Kotlin, JVM-tested (HandsFreeTest).

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core

/** How much the tools say. "Short answers", "normal answers", "detailed answers". */
enum class Verbosity {
  SHORT,
  NORMAL,
  DETAILED;

  companion object {
    fun fromName(name: String?): Verbosity = entries.firstOrNull { it.name == name } ?: NORMAL
  }
}

/** Everything the mode store keeps. */
data class ModeSettings(
    val handsFree: Boolean = false,
    /** The glasses display card, when the glasses have a display ("glasses display off"). */
    val glassesDisplay: Boolean = true,
    val verbosity: Verbosity = Verbosity.NORMAL,
    /** Which camera the tools use (notes/phone-camera.md). */
    val cameraSource: CameraSourceSetting = CameraSourceSetting.AUTO,
    /** "Use my phone's camera" was chosen on the setup screen: skip Meta AI registration. */
    val phoneChosen: Boolean = false,
)

/** What a mode means for each behaviour that used to be always on. */
data class HandsFreePolicy(val handsFree: Boolean) {
  /** The mic runs while the app is in use (glasses first, then the phone). Else push to talk. */
  val alwaysListening: Boolean
    get() = handsFree

  /** "Connecting to your glasses", "SpeakUp is ready...", screen changes. Tools still speak results. */
  val narrateStartup: Boolean
    get() = handsFree

  /** Silence reminders (IdleNudge) saying what to say next. */
  val idleReminders: Boolean
    get() = handsFree

  /** No dialogs: the camera permission prompt is replaced by speech, then Meta AI opens. */
  val replaceDialogs: Boolean
    get() = handsFree

  /** Pitfalls (Bluetooth off, disconnected...) spoken with no tool open. A tool always hears them. */
  val speakAlertsAtHome: Boolean
    get() = handsFree

  /** A lost stream with no tool open is reconnected by itself (in the toolbox the user decides). */
  val reconnectAtHome: Boolean
    get() = handsFree

  /** The setup screen greets, listens and reminds. In the toolbox it waits for a tap. */
  val setupConversation: Boolean
    get() = handsFree
}

/** What switching the mode should say. */
enum class ModeChange {
  TURNED_ON,
  TURNED_OFF,
  ALREADY_ON,
  ALREADY_OFF,
}

/** The result of the first-run check. [announce]: say "Hands-free is on..." once. */
data class FirstRun(val handsFree: Boolean, val announce: Boolean)

object HandsFreeRules {

  /**
   * [stored] is the saved setting, or null if it has never been set (first run). On first run a
   * running screen reader turns hands-free on, and that is announced once; otherwise the toolbox.
   */
  fun firstRun(stored: Boolean?, screenReaderOn: Boolean): FirstRun =
      if (stored != null) FirstRun(stored, announce = false)
      else FirstRun(handsFree = screenReaderOn, announce = screenReaderOn)

  /** A launch through a hands-free entry point switches the mode on (and keeps it on). */
  fun afterLaunch(current: Boolean, launchedHandsFree: Boolean): Boolean = current || launchedHandsFree

  fun change(was: Boolean, wanted: Boolean): ModeChange =
      when {
        wanted && was -> ModeChange.ALREADY_ON
        wanted -> ModeChange.TURNED_ON
        was -> ModeChange.TURNED_OFF
        else -> ModeChange.ALREADY_OFF
      }

  /**
   * A tool launched straight in by its own launcher entry, deep link or extra ("Hey Google, open
   * Mail Reader") is a voice-first visit: it listens and narrates for that visit even in the
   * toolbox, without changing the saved setting.
   */
  fun effective(saved: Boolean, voiceFirstToolLaunch: Boolean): HandsFreePolicy =
      HandsFreePolicy(saved || voiceFirstToolLaunch)
}

/** The launch-intent parts that can ask for hands-free mode. */
data class HandsFreeIntent(
    /** Boolean extra "handsfree" (`--ez handsfree true`). */
    val handsFreeExtra: Boolean = false,
    /** Deep link parts: speakup://handsfree (the launcher shortcut uses the same link). */
    val scheme: String? = null,
    val host: String? = null,
)

object HandsFreeLaunch {
  const val SCHEME = "speakup"
  const val HOST = "handsfree"
  const val EXTRA = "handsfree"

  fun isHandsFree(launch: HandsFreeIntent): Boolean =
      launch.handsFreeExtra ||
          (launch.scheme.equals(SCHEME, ignoreCase = true) && launch.host.equals(HOST, ignoreCase = true))
}
