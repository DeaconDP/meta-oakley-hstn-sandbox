// WatchGrammar - what the user says to and inside "Watch for text"
//
// [opens]: the phrases that open this tool from any tool ("watch for 42", "tell me when you see
// exit", "look out for platform 9", "find Boots"), with what to watch for as the request's argument.
// GlobalGrammar calls it; add synonyms here, not there. [parse]: commands inside the tool: stop
// watching, carry on watching, what are you watching for, where is it, watch for something else
// (with or without the new target), a new "watch for X", and the alive tick (off, on, every N
// seconds). ToolHub tries [parse] before the global grammar, so it doesn't claim phrases that open
// other tools, and leaves "stop", "close", "help" and the rest to the global grammar. Pure Kotlin
// (no Android imports), JVM-tested.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.watch

import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.Phrases
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolRequest

/** Commands inside Watch for text. */
sealed interface WatchCommand {
  /** Stop watching (the target is kept, so "carry on watching" restarts it). */
  data object Stop : WatchCommand

  /** Start watching again for the same target. */
  data object Resume : WatchCommand

  /** "What are you watching for?" */
  data object WhatTarget : WatchCommand

  /** "Where is it?" */
  data object Where : WatchCommand

  /** Watch for something else: [target] as said, or null to ask for it. */
  data class NewTarget(val target: String?) : WatchCommand

  /** The alive tick: [seconds] between ticks, 0 = off, null = back on at the default. */
  data class Ticks(val seconds: Int?) : WatchCommand
}

object WatchGrammar {

  private const val LEAD =
      "(?:(?:start |keep )?watch(?:ing)? (?:out )?for|look(?:ing)? out for|keep an eye out for|" +
          "(?:tell|let) me (?:know )?(?:when|if) you see|find(?: me)?(?! out(?: |$))|look for)"

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

  // MARK: commands inside the tool. Ordered: specific phrases first.

  private val STOP =
      Regex(
          "^(?:(?:stop|cancel|quit|end|finish|pause) (?:watching|looking|searching)(?: for (?:it|that|this|now|.{1,30}))?|" +
              "don'?t (?:watch|look) (?:for (?:it|that) )?any ?more|never mind|forget (?:it|that)|cancel)$",
      )

  private val RESUME =
      Regex(
          "^(?:(?:start|keep|carry on|continue|resume|go on|go back to) (?:watching|looking)(?: for it)?(?: again)?|" +
              "watch again|start again|keep going)$",
      )

  private val WHAT_TARGET =
      Regex(
          "^(?:what (?:are|am|were) (?:you|i|we) (?:watching|looking|waiting|searching) (?:out )?for|" +
              "what'?s the target|what (?:are|were) you (?:told|asked) to (?:watch|look) for|" +
              "what (?:did|do) i (?:ask|tell) you to (?:watch|look) for|what (?:are|was) it)$",
      )

  private val WHERE =
      Regex(
          "^(?!where (?:am|are (?:we|you)|did (?!you)))(?:where(?:'s| is| was| are)?(?: [\\w']+){0,3}|which (?:side|way)(?: is it| was it)?|" +
              "where did you (?:last )?see it)$",
      )

  private val SOMETHING_ELSE_LEAD =
      Regex("(?:^| )(?:(?:watch|look) (?:out )?for something else|something else|change (?:it |the target )?to|instead watch for|now watch for)(?= |$)")

  private val SOMETHING_ELSE = Regex("^(?:(?:watch|look) (?:out )?for something else|something else|change (?:it |the target )?to|instead watch for|now watch for)(?: .+)?$")

  private val TICKS_OFF =
      Regex(
          "^(?:(?:turn |switch )?(?:the )?(?:ticks?|ticking|clicks?|clicking)(?: sound)? off|" +
              "(?:turn off|switch off|stop|no|mute|no more)(?: the)? (?:ticks?|ticking|clicks?|clicking)|stop ticking)$",
      )

  private val TICKS_ON =
      Regex("^(?:(?:turn |switch )?(?:the )?(?:ticks?|ticking|clicks?) (?:back )?on|(?:turn|switch) (?:the )?(?:ticks?|ticking|clicks?) (?:back )?on|(?:turn|switch) on (?:the )?(?:ticks?|ticking|clicks?)|start ticking)$")

  private val TICKS_EVERY =
      Regex("^(?:tick(?:s|ing)?|click(?:s|ing)?) (?:once )?every ([a-z0-9 ]+?) seconds?$")

  /**
   * A command inside the tool, or null. [normalized] is Phrases.normalize(transcript); [light] is
   * Phrases.light(transcript), used for a new target so it keeps every word.
   */
  fun parse(normalized: String, light: String = normalized): WatchCommand? {
    if (normalized.isEmpty()) return null
    if (TICKS_OFF.matches(normalized)) return WatchCommand.Ticks(0)
    if (TICKS_ON.matches(normalized)) return WatchCommand.Ticks(null)
    TICKS_EVERY.find(normalized)?.let { m ->
      val n = NumberWords.parse(m.groupValues[1].split(' ').filter { it.isNotEmpty() })?.toIntOrNull()
      if (n != null && n > 0) return WatchCommand.Ticks(n)
    }
    if (SOMETHING_ELSE.matches(normalized)) {
      val after = Phrases.after(SOMETHING_ELSE_LEAD, light)?.removePrefix("then ")?.trim()
      return WatchCommand.NewTarget(after?.takeUnless { it.isEmpty() || it in NO_TARGET })
    }
    if (STOP.matches(normalized)) return WatchCommand.Stop
    if (RESUME.matches(normalized)) return WatchCommand.Resume
    if (WHAT_TARGET.matches(normalized)) return WatchCommand.WhatTarget
    if (WHERE.matches(normalized)) return WatchCommand.Where
    // "watch for 73" while watching: a new target (same phrases that open the tool).
    opens(normalized, light)?.let { r -> return WatchCommand.NewTarget(r.argument) }
    return null
  }
}
