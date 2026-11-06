// WatchGrammar - what the user says to and inside "Watch for text"
//
// [opens]: the phrases that open this tool from any tool ("watch for 42", "tell me when you see
// exit", "look out for platform 9"), with what to watch for as the request's argument. GlobalGrammar
// calls it; add synonyms here, not there. [parse]: commands inside the tool (none yet: this tool is a
// stub; the feature agent adds them). ToolHub tries [parse] before the global grammar, so don't claim
// phrases that open other tools. Pure Kotlin (no Android imports), JVM-tested.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.watch

import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.Phrases
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolRequest

/** Commands inside Watch for text. Add them here (e.g. a new target, stop watching). */
sealed interface WatchCommand

object WatchGrammar {

  private const val LEAD =
      "(?:(?:start |keep )?watch(?:ing)? (?:out )?for|look(?:ing)? out for|keep an eye out for|" +
          "(?:tell|let) me (?:know )?(?:when|if) you see|find me|look for)"

  private val OPEN_WITH_TARGET = Regex("^$LEAD .+$")
  private val LEAD_IN_LIGHT = Regex("(?:^| )$LEAD(?= )")
  private val OPEN_TOOL =
      Regex("^(?:(?:open|start|switch to)(?: the)? )?watch(?:ing)? for text(?: tool)?$|^text watcher$")

  /** Words that mean "the tool itself", not a target. */
  private val NO_TARGET = setOf("text", "something", "words", "a word", "a number")

  fun opens(normalized: String, light: String): ToolRequest? {
    if (OPEN_TOOL.matches(normalized)) return ToolRequest(ToolId.WATCH)
    if (!OPEN_WITH_TARGET.matches(normalized)) return null
    val target = Phrases.after(LEAD_IN_LIGHT, light)?.removePrefix("the ")?.trim()
    return ToolRequest(ToolId.WATCH, argument = target?.takeUnless { it in NO_TARGET })
  }

  /** A command inside the tool, or null. [normalized] is Phrases.normalize(transcript). */
  @Suppress("UNUSED_PARAMETER")
  fun parse(normalized: String): WatchCommand? = null
}
