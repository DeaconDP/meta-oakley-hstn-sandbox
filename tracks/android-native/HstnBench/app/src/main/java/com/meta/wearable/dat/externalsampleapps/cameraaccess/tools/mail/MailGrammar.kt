// MailGrammar - what the user says to and inside the mail reader
//
// [opens]: the phrases that open this tool from any tool ("read my mail", "what is this letter").
// GlobalGrammar calls it; add synonyms here, not there. [parse]: commands inside the tool (none yet:
// this tool is a stub; the feature agent adds "read it all", "who is it from", ...). ToolHub tries
// [parse] before the global grammar, so don't claim phrases that open other tools.
// Pure Kotlin (no Android imports), JVM-tested.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.mail

import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolRequest

/** Commands inside the mail reader. Add them here. */
sealed interface MailCommand

object MailGrammar {

  private val OPEN =
      Regex(
          "^(?:(?:read|check|open|look at|go through)(?: (?:my|the|this|today'?s))? (?:mail|post|letters?|envelope)|" +
              "(?:open |start |switch to )?(?:the )?mail reader|mail|" +
              "what(?:'s| is) (?:this|that|the) (?:letter|envelope)(?: about)?|" +
              "what does (?:this|the) letter say|who(?:'s| is) (?:this|the) letter (?:from|for)|" +
              "is this (?:letter )?(?:a bill|junk mail|for me))$",
      )

  fun opens(normalized: String, @Suppress("UNUSED_PARAMETER") light: String): ToolRequest? =
      if (OPEN.matches(normalized)) ToolRequest(ToolId.MAIL) else null

  /** A command inside the tool, or null. [normalized] is Phrases.normalize(transcript). */
  @Suppress("UNUSED_PARAMETER")
  fun parse(normalized: String): MailCommand? = null
}
