// MailGrammar - what the user says to and inside the mail reader
//
// [opens]: the phrases that open this tool from any tool ("read my mail", "what is this letter").
// GlobalGrammar calls it; add synonyms here, not there. [parse]: commands inside the tool: "what is
// this letter" / "read" (photograph and summarise), "read it all", "who's it from", "who's it for",
// "how much", "when is it due", "is it junk", "what kind of letter", "what's the date", "what's the
// reference", "read the envelope", "next page", "new letter", "back", "skip", "start again",
// "summary". Ordered rules, longer phrases before the short words inside them (book/VoiceCommands
// style). ToolHub tries [parse] before the global grammar, so nothing here may match another tool's
// opening phrase ("read the label", "read a book") or a global command it doesn't mean to replace.
// Pure Kotlin (no Android imports), JVM-tested.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.mail

import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolRequest

/** Commands inside the mail reader. */
sealed interface MailCommand {
  /** Photograph what's held up and give the short summary. */
  data object Summarise : MailCommand

  /** Say the summary of the current letter again (no new photo). */
  data object Summary : MailCommand

  data object ReadAll : MailCommand

  data object StartAgain : MailCommand

  data object From : MailCommand

  data object For : MailCommand

  data object HowMuch : MailCommand

  data object WhenDue : MailCommand

  data object IsJunk : MailCommand

  data object Kind : MailCommand

  data object Date : MailCommand

  data object Reference : MailCommand

  /** Photograph and describe as an envelope. */
  data object Envelope : MailCommand

  /** Photograph another page of the same letter. */
  data object NextPage : MailCommand

  /** Forget this letter and photograph a new one. */
  data object NewLetter : MailCommand

  data object Back : MailCommand

  data object Skip : MailCommand
}

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

  private class Rule(pattern: String, val command: MailCommand) {
    val regex = Regex("^(?:$pattern)$")
  }

  private const val IT = "(?:it|this|that|this letter|the letter|this one|that one)"

  private val RULES =
      listOf(
          Rule("(?:read|say|tell me) (?:it all|all of it|the whole (?:letter|thing|lot)|everything|every word|the full letter|the lot|the rest)|" +
              "read (?:it )?(?:out )?in full|read (?:it|the letter) out|read all", MailCommand.ReadAll),
          Rule("(?:start|read it|read) (?:again|from the (?:top|start|beginning))|from the (?:top|start|beginning)|start over", MailCommand.StartAgain),
          Rule("(?:read|look at|check|what(?:'s| is) on) (?:the|this) envelope|is (?:this|it) (?:an|the) envelope", MailCommand.Envelope),
          Rule("(?:next|another|add a|add another|turn the|the next|there(?:'s| is) another|one more) page|page (?:two|three|four|2|3|4)|i(?:'ve| have) turned (?:it )?over|turn(?:ed)? over", MailCommand.NextPage),
          Rule("(?:new|another|next|a different) letter|(?:here(?:'s| is)|try) (?:another|the next) one|next one", MailCommand.NewLetter),
          Rule("who(?:'s| is| was) $IT (?:from)|who (?:sent|wrote) $IT|who(?:'s| is) the sender|who(?:'s| is) it from|from who(?:m)?", MailCommand.From),
          Rule("who(?:'s| is| was) $IT (?:for|to|addressed to)|who(?:'s| is) it addressed to|is (?:it|this) (?:for|addressed to) me|who(?:'s| is) the (?:recipient|addressee)", MailCommand.For),
          Rule("how much(?: (?:is it|is that|do i owe|do i (?:have|need) to pay|is due|money|is the bill|are they asking for|should i pay))?|" +
              "what(?:'s| is) the (?:amount|total|balance|bill)(?: due)?|what do i (?:owe|have to pay)|(?:the )?amount(?: due)?", MailCommand.HowMuch),
          Rule("when(?:'s| is) (?:it|this|that|the bill|the payment) due|when (?:do|should|must) i (?:have to |need to )?(?:pay|reply|respond)(?: by)?|" +
              "what(?:'s| is) the (?:due date|deadline)|(?:the )?(?:due date|deadline)|when(?:'s| is) the (?:deadline|appointment)|pay by when", MailCommand.WhenDue),
          Rule("is (?:it|this|that) (?:junk|junk mail|spam|an advert|advertising|a flyer|important)|(?:is it|is this) junk", MailCommand.IsJunk),
          Rule("what (?:kind|type|sort) of (?:letter|thing|mail) is (?:it|this|that)|what (?:kind|type|sort) (?:is it|of letter)|is (?:it|this) a bill", MailCommand.Kind),
          Rule("what(?:'s| is) the date(?: on (?:it|this|the letter))?|when was (?:it|this) (?:sent|written|dated)|what date is (?:it|this) (?:from|dated)", MailCommand.Date),
          Rule("what(?:'s| is) (?:the|my) (?:account|reference|customer|policy|nhs|invoice) number|(?:read|say) the (?:account|reference) number|what(?:'s| is) the reference|reference number|account number", MailCommand.Reference),
          Rule("(?:give me |say )?(?:the |a )?summary(?: again)?|summari[sz]e(?: it)?|sum (?:it )?up|tell me again|what was it again", MailCommand.Summary),
          Rule("(?:go )?back(?: a (?:sentence|bit|line))?|previous(?: sentence)?|last sentence|say the last (?:sentence|bit|line)", MailCommand.Back),
          Rule("skip(?: (?:this|that|ahead|it|forward|a sentence))?|next(?: sentence)?|forward", MailCommand.Skip),
          Rule("read|read (?:it|this|the letter|this letter|it to me|my letter)|look(?: at it)? again|try again|scan (?:it|this letter)|" +
              "what(?:'s| is) (?:this|that|it)(?: about)?|what(?:'s| is) (?:this|that|the) (?:letter|envelope)(?: about)?|what does (?:it|this|the letter) say|" +
              "what(?:'s| is) in (?:this|the) letter|who(?:'s| is) (?:this|the) letter from|is this (?:letter )?(?:a bill|junk mail|for me)", MailCommand.Summarise),
      )

  /** A command inside the tool, or null. [normalized] is Phrases.normalize(transcript). */
  fun parse(normalized: String): MailCommand? {
    if (normalized.isEmpty()) return null
    for (rule in RULES) if (rule.regex.matches(normalized)) return rule.command
    return null
  }
}
