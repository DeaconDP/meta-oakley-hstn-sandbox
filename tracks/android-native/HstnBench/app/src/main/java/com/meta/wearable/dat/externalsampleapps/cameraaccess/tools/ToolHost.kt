// ToolHost - what a tool tells ToolHub, and what ToolHub tells the tool
//
// ToolHub (one per activity) owns everything voice-first that every tool needs: the glasses link
// and its narration, the microphone (glasses first, phone fallback), the echo guard, the speech
// engine and earcons, the spoken pitfalls (Bluetooth, battery, heat, taken off, folded...), the
// silence reminders, switching tools by voice and "ask about the text". A tool's ViewModel
// implements ToolHost and attaches while its screen is open. Everything here has a sensible default
// so a new tool only overrides what it cares about. New tools usually extend ToolViewModel, which
// implements this for them; the book reader implements it directly.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools

import android.content.Context
import androidx.annotation.StringRes
import com.meta.wearable.dat.externalsampleapps.cameraaccess.R
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.GlobalCommand
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.HealthAlert
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolRequest

/** How the tool came to be open, so it can choose what to say first. */
enum class OpenReason {
  /** A button on the phone screen; the stream is usually already up. */
  TAPPED,
  /** Launched straight into the tool (launcher alias, deep link, intent extra): voice-first. */
  LAUNCHED,
  /** Asked for by voice from another tool. ToolHub has already said the tool's name. */
  SWITCHED,
}

/** The lines ToolHub speaks on a tool's behalf. [ToolTexts.generic] fills them in from a name. */
data class ToolTexts(
    /** Said when switching to this tool ("Mail reader."), without the full stop. */
    val name: String,
    /** Voice-first launch, while the link comes up. */
    val connecting: String,
    /** Voice-first launch, once the glasses camera is streaming. */
    val ready: String,
    /** Opened with the stream already running (a tap). */
    val welcome: String,
    /** Opened by voice from another tool, after ToolHub said [name]. Blank to say nothing more. */
    val welcomeAfterSwitch: String,
    /** "help". */
    val help: String,
    /** The stream dropped and no health alert explained why. */
    val streamLost: String,
    /** The glasses paused the camera (a tap on the frame). */
    val pausedByGlasses: String,
    /** The stream came back after a loss. */
    val cameraBack: String,
    /** Camera permission was refused. */
    val cameraDenied: String,
    /** Said when the tool closes by voice. */
    val goodbye: String,
) {
  companion object {
    /**
     * Texts for a tool called [nameRes] ("Mail reader"), with [helpRes] as its help, from the shared
     * strings_tools.xml templates.
     */
    fun generic(context: Context, @StringRes nameRes: Int, @StringRes helpRes: Int): ToolTexts {
      val name = context.getString(nameRes)
      return ToolTexts(
          name = name,
          connecting = context.getString(R.string.tool_connecting, name),
          ready = context.getString(R.string.tool_ready),
          welcome = context.getString(R.string.tool_welcome, name),
          welcomeAfterSwitch = "",
          help = context.getString(helpRes),
          streamLost = context.getString(R.string.tool_stream_lost),
          pausedByGlasses = context.getString(R.string.tool_paused_by_glasses),
          cameraBack = context.getString(R.string.tool_camera_back),
          cameraDenied = context.getString(R.string.tool_camera_denied),
          goodbye = context.getString(R.string.tool_goodbye),
      )
    }
  }
}

interface ToolHost {
  val toolId: ToolId

  /** Lines ToolHub speaks for this tool. Called when needed, so they can depend on state. */
  fun texts(): ToolTexts

  /** Attached (screen open). Reset per-visit state here. [request] carries mode and argument. */
  fun onAttached(request: ToolRequest) = Unit

  /**
   * The tool is ready to talk: after the welcome or connect narration (LAUNCHED/TAPPED) or after
   * the tool's name (SWITCHED). Say what the tool is doing first here.
   */
  fun onOpened(request: ToolRequest, reason: OpenReason) = Unit

  /** Opened again while already open, with a new [request] ("watch for 43" while watching 42). */
  fun onRequest(request: ToolRequest) = Unit

  /** Leaving: closed, or switching to another tool. Stop work and save state (the bookmark). */
  fun onLeaving() = Unit

  /** Detached (screen gone). */
  fun onDetached() = Unit

  /** Speech rate this tool reads at, or null to use the shared tools rate. */
  fun speechRate(): Float? = null

  // MARK: speech engine

  /** A ToolHub.sayAside line finished (not cut off). The book reader resumes reading here. */
  fun onAsideDone() = Unit

  /** A ToolHub.speak(text, tag) utterance finished (not cut off). */
  fun onSpoken(tag: String) = Unit

  fun onEngineState(available: Boolean) = Unit

  // MARK: voice

  /** A partial transcript (barge-in). Return true if handled. */
  fun onPartial(text: String): Boolean = false

  /** A final transcript that isn't our own echo, before any parsing. Show it on screen. */
  fun onHeard(text: String) = Unit

  /** The tool's own grammar. Return true if [text] was a command for this tool. */
  fun onCommand(text: String): Boolean = false

  /** A global command, before ToolHub's default handling. Return true if handled. */
  fun onGlobal(command: GlobalCommand): Boolean = false

  /** Neither grammar understood [text]. Usually ToolHub.sayNotUnderstood(text, busy). */
  fun onNotUnderstood(text: String) = Unit

  // MARK: silence reminders

  /** True when nothing will happen until the user speaks (nothing reading, capturing, retrying). */
  fun isWaitingForUser(): Boolean = false

  /** What to say after a silence; [index] 0 is the first reminder, [last] the final one. */
  fun reminder(index: Int, last: Boolean): String? = null

  // MARK: pitfalls

  /** A status line for the screen (ToolHub.warn/say mirror what they speak here). */
  fun onStatus(text: String) = Unit

  /**
   * A glasses/phone condition changed. Do side effects (pause, save) here, and return text to say
   * instead of ToolHub's default line, or null for the default.
   */
  fun onHealthAlert(alert: HealthAlert): String? = null

  /** The stream dropped (fold, session end). Return false to ignore it (nothing running). */
  fun onStreamLost(): Boolean = true

  fun onStreamBack() = Unit
}
