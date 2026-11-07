// ToolId - the everyday tools the app can open, and how a request to open one is described
//
// Each tool has a stable id used everywhere a tool is named from outside the code: the deep link
// (hstnbench://<id>), the intent extra (--es tool <id>), the launcher alias, the resource file
// (res/values/strings_<id>.xml) and the package (tools/<id>/). A ToolRequest is "open this tool",
// optionally with a mode ("colour" for the light tool) and an argument (what to watch for).
// Requests come from a launcher entry, a deep link, a button, or a voice command in any tool.
// Pure Kotlin, JVM-tested.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core

enum class ToolId(val id: String) {
  /** Reads a printed book aloud, page by page (bookreader/). */
  BOOK("book"),
  /** "What is this letter?": sender, recipient, subject, amounts; then read it all (tools/mail/). */
  MAIL("mail"),
  /** "Tell me when you see 42": continuous OCR on the stream (tools/watch/). */
  WATCH("watch"),
  /** Barcodes and labels read word for word (tools/labels/). */
  LABELS("labels"),
  /** Light probe tone and "what colour is this?" (tools/light/). */
  LIGHT("light");

  companion object {
    fun fromId(id: String?): ToolId? = entries.firstOrNull { it.id.equals(id?.trim(), ignoreCase = true) }
  }
}

/**
 * Open [tool]. [mode] picks a sub-mode ([MODE_COLOUR] for the light tool). [argument] is free text
 * the tool interprets: the target for "watch for 42" is "42".
 */
data class ToolRequest(val tool: ToolId, val mode: String? = null, val argument: String? = null) {
  companion object {
    /** Light tool: name the colour in the middle of the view instead of the brightness tone. */
    const val MODE_COLOUR = "colour"
  }
}

/**
 * How a launch intent names a tool, without Android types so it can be tested on the JVM.
 * MainActivity fills this in from the Intent.
 */
data class LaunchIntent(
    /** Class name of the component that was launched (an activity-alias for launcher entries). */
    val componentClass: String? = null,
    /** String extra "tool" (`--es tool mail`). */
    val toolExtra: String? = null,
    /** String extras "tool_mode" and "tool_arg". */
    val modeExtra: String? = null,
    val argExtra: String? = null,
    /** Boolean extra "book_reader" (`--ez book_reader true`), kept from the first book reader. */
    val bookReaderExtra: Boolean = false,
    /** Deep link parts: hstnbench://<host>?mode=..&arg=.. */
    val scheme: String? = null,
    val host: String? = null,
    val queryMode: String? = null,
    val queryArg: String? = null,
)

object ToolLaunch {
  const val SCHEME = "hstnbench"
  const val EXTRA_TOOL = "tool"
  const val EXTRA_MODE = "tool_mode"
  const val EXTRA_ARG = "tool_arg"
  const val EXTRA_BOOK_READER = "book_reader"
  const val QUERY_MODE = "mode"
  const val QUERY_ARG = "arg"

  /** Launcher activity-alias suffix per tool ("Hey Google, open Mail Reader"). */
  val LAUNCHER_ALIASES: Map<ToolId, String> =
      mapOf(
          ToolId.BOOK to ".BookReaderLauncher",
          ToolId.MAIL to ".MailReaderLauncher",
          ToolId.WATCH to ".WatchForTextLauncher",
          ToolId.LABELS to ".LabelReaderLauncher",
          ToolId.LIGHT to ".LightDetectorLauncher",
      )

  /** The tool this launch asks for, or null for the normal camera screen. */
  fun parse(launch: LaunchIntent): ToolRequest? {
    launch.componentClass?.let { cls ->
      LAUNCHER_ALIASES.entries.firstOrNull { cls.endsWith(it.value) }?.let { return ToolRequest(it.key) }
    }
    ToolId.fromId(launch.toolExtra)?.let {
      return ToolRequest(it, launch.modeExtra.nonBlank(), launch.argExtra.nonBlank())
    }
    if (launch.bookReaderExtra) return ToolRequest(ToolId.BOOK)
    if (launch.scheme.equals(SCHEME, ignoreCase = true)) {
      ToolId.fromId(launch.host)?.let {
        return ToolRequest(it, launch.queryMode.nonBlank(), launch.queryArg.nonBlank())
      }
    }
    return null
  }

  private fun String?.nonBlank(): String? = this?.trim()?.takeIf { it.isNotEmpty() }
}
