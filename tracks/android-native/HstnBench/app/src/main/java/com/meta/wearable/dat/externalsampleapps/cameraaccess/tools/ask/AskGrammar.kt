// AskGrammar - spotting a question about text that was just read
//
// "What does ephemeral mean?", "who is Mr. Bennet?", "what happened last time?" are questions for
// AskAboutText, not commands. GlobalGrammar calls [parse] after the tool-opening phrases and before
// the generic commands. The ask feature agent can widen these patterns here without touching
// GlobalGrammar. Phrases a tool already uses are answered by that tool first ("where am I" in the
// book reader), so this only sees what no tool claimed. Pure Kotlin, JVM-tested.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ask

import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.GlobalCommand

object AskGrammar {

  private class Rule(pattern: String, val subjectGroup: Int = 1) {
    val regex = Regex("^(?:$pattern)$")
  }

  private val RULES =
      listOf(
          Rule("what does (?:the word )?(.+?) mean"),
          Rule("what(?:'s| is) the (?:meaning|definition) of (?:the word )?(.+)"),
          Rule("what(?:'s| is| are) (?:a |an )?(.+?) again"),
          Rule("(?:define|meaning of) (?:the word )?(.+)"),
          Rule("who(?:'s| is| was| are| were) (?!this letter)(.+)"),
          Rule("what happened(?: (.+))?"),
          Rule("why (?:did|does|is|was|were|are) (.+)"),
          Rule("where (?:did|does|was|were) (.+)"),
          Rule("what did (?!it |you |that )(.+?) (?:say|do|mean)(?: .*)?"),
          Rule("how do you (?:spell|say) (.+)"),
          Rule("(?:does it|did it|does the (?:text|book|letter|page)) say (.+)"),
      )

  /** An Ask command if [normalized] is a question about the text; [original] is kept as asked. */
  fun parse(normalized: String, original: String): GlobalCommand.Ask? {
    for (rule in RULES) {
      val m = rule.regex.matchEntire(normalized) ?: continue
      val subject = m.groups[rule.subjectGroup]?.value?.trim()?.takeIf { it.isNotEmpty() }
      return GlobalCommand.Ask(question = original.trim(), subject = subject)
    }
    return null
  }
}
