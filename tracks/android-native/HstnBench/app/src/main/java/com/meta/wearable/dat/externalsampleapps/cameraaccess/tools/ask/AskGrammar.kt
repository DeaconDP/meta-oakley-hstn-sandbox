// AskGrammar - spotting a question about text that was just read, and what kind it is
//
// "What does ephemeral mean?", "who is Mr. Bennet?", "what happened last time?" are questions for
// AskAboutText, not commands. GlobalGrammar calls [parse] after the tool-opening phrases and before
// the generic commands. Phrases a tool already uses are answered by that tool first ("where am I",
// "next one" in the book reader), so this only sees what no tool claimed.
//
// [classify] says which kind of question it is, so the on-device answerer (OnDeviceAsk) knows what
// to do: define a word, spell it, say who someone is, recap, find a passage, or (anything else) an
// open question it can't answer without the optional Claude path.
//
// Follow-ups ("more", "next", "no") are short words the room says all the time, so they only count
// for a while after an answer that offers them: OnDeviceAsk opens [FollowUps] and they expire.
// "Spell it" is always a question (nobody says it by accident). Pure Kotlin, JVM-tested.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ask

import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.GlobalCommand
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.Phrases

enum class AskKind {
  /** "What does recondite mean", "define", "what's a hansom". */
  DEFINE,
  /** "Spell recondite", "how do you spell it". Subject null = the last word talked about. */
  SPELL,
  /** "Who is Mr. Bennet", "who's Watson". */
  WHO,
  /** "What's the Time Machine": a name in the text if it's there, else a dictionary word. */
  WHAT,
  /** "What happened last time", "recap", "where did we leave off". [AskQuestion.lastTime] for "last time". */
  RECAP,
  /** "What did it say about the fire", "find the stick". */
  FIND,
  /** Follow-up: further senses, mentions or matches. */
  MORE,
  /** Follow-up: "no" after "Did you mean recondite?": define the word as heard. */
  NO,
  /** Anything else ("why did he do that?"). Only the optional Claude path can try these. */
  OPEN,
}

data class AskQuestion(val kind: AskKind, val subject: String? = null, val lastTime: Boolean = false)

object AskGrammar {

  /** Which follow-ups count right now, until when. Opened by OnDeviceAsk after an answer. */
  object FollowUps {
    @Volatile private var kinds: Set<AskKind> = emptySet()
    @Volatile private var untilMs = 0L
    var clock: () -> Long = System::currentTimeMillis

    /** "more"/"next" for [ms] (and "no" if [no]). */
    fun open(more: Boolean, no: Boolean, ms: Long = WINDOW_MS) {
      kinds = buildSet {
        if (more) add(AskKind.MORE)
        if (no) add(AskKind.NO)
      }
      untilMs = clock() + ms
    }

    fun close() {
      kinds = emptySet()
    }

    fun allowed(kind: AskKind): Boolean = kind in kinds && clock() < untilMs

    const val WINDOW_MS = 120_000L
  }

  private class Rule(pattern: String, val kind: AskKind, val lastTime: Boolean = false) {
    val regex = Regex("^(?:$pattern)$")
  }

  private const val WORD = "(?:the )?(?:word |name )?"
  private const val TEXT = "(?:it|the (?:text|book|letter|page|story|chapter|author)|he|she|they|you)"

  /** "What is the X" subjects that aren't about the text. */
  private val NOT_TEXT =
      Regex(
          "^(?:time|date|day|weather|forecast|battery|batteries|matter|problem|point|page|speed|rate|" +
              "plan|score|news|deal|password|wifi|price|cost|colou?r(?: .*)?|light(?: .*)?|" +
              "time now|best .*|nearest .*|next .*)$",
      )

  private val RULES =
      listOf(
          // Follow-ups first (they're gated).
          Rule("more|tell me more|more (?:meanings?|please)|(?:any )?other meanings?|what else|anything else|" +
              "next|next (?:match|mention|bit|part|sentence)|find (?:the )?next|find (?:it )?again|another|another one", AskKind.MORE),
          Rule("(?:no|nope|no not that(?: one)?|not that one|(?:no )?the (?:other|first) one|no (?:the )?one i said|" +
              "no i meant (?:what i said|the one i said)|that'?s not (?:it|what i said))", AskKind.NO),
          // Spelling.
          Rule("(?:spell|spell out|how do you spell|how is|how'?s) (?:it|that|the word|that word|this word)(?: spelt| spelled)?(?: again)?", AskKind.SPELL),
          Rule("(?:how do (?:you|i) spell|spell|spell out|can i have the spelling of|spelling of) $WORD(.+?)", AskKind.SPELL),
          Rule("how (?:is|do you write) $WORD(.+?) (?:spelt|spelled|written)", AskKind.SPELL),
          // Definitions.
          Rule("what does $WORD(.+?) mean(?: again)?", AskKind.DEFINE),
          Rule("what(?:'s| is| was) the (?:meaning|definition) of $WORD(.+)", AskKind.DEFINE),
          Rule("(?:define|meaning of|definition of|look up|dictionary) $WORD(.+)", AskKind.DEFINE),
          Rule("what(?:'s| is) (?:a |an )(.+?)(?: again)?", AskKind.DEFINE),
          Rule("what(?:'s| is| are) (.+?) again", AskKind.DEFINE),
          Rule("what do(?:es)? (?:you mean by|they mean by|it mean by) $WORD(.+)", AskKind.DEFINE),
          // Recap (before the open "where did ..." rule).
          Rule("what happened (?:last time|the last time|before|previously|in the last (?:session|chapter|bit)|yesterday|then|last)", AskKind.RECAP, lastTime = true),
          Rule("where (?:did|do) (?:we|i) (?:leave off|leave it|stop|get to|finish|break off)(?: last time)?|where were we|" +
              "what was (?:i|we) reading(?: last time)?|remind me where (?:we|i) (?:were|was|left off)", AskKind.RECAP, lastTime = true),
          Rule("what happened(?:(?: so)? far| just now| there| earlier)?|recap|give me a recap|a recap|recap (?:please|(?:so )?far|that)|" +
              "summar(?:ise|ize)(?: (?:it|that|(?:so )?far))?|remind me what happened|what'?s been happening|what did i miss|" +
              "catch me up|what was that (?:bit|part) about", AskKind.RECAP),
          // Finding.
          Rule("what (?:did|does) $TEXT (?:say|said|tell (?:me|us)|mention) about (.+)", AskKind.FIND),
          Rule("(?:did|does|has) $TEXT (?:say|mention) (?:(?:anything|something) )?about (.+)|(?:did|does|has) $TEXT mention (.+)", AskKind.FIND),
          Rule("(?:find|search for|search|where does it (?:mention|say|talk about)|" +
              "read (?:me )?(?:the )?(?:bit|part|sentence) (?:about|with)|go back to (?:the )?(?:bit|part) about) (.+)", AskKind.FIND),
          Rule("where (?:was|were|is|are) (.+?) mentioned", AskKind.FIND),
          Rule("what did (?!it |you |that |i |we )(.+?) say(?: .*)?", AskKind.FIND),
          // Who and what.
          Rule("who(?:'s| is| was| are| were) (?!this letter|that letter|it from|there|calling|that at)(.+?)(?: again)?", AskKind.WHO),
          Rule("(?:remind me who|tell me who) (.+?) (?:is|was)", AskKind.WHO),
          Rule("what(?:'s| is| was| are| were) the (.+?)(?: again)?", AskKind.WHAT),
          // Open questions: only the optional Claude path can try these.
          Rule("why (?:did|does|do|is|was|were|are|would|didn'?t|doesn'?t|has|had) (.+)", AskKind.OPEN),
          Rule("where (?:did|does|was|were|is|are) (.+)", AskKind.OPEN),
          Rule("how (?:did|does|do|is|was|were|old|many|much|long) (.+)", AskKind.OPEN),
          Rule("what did (?!it |you |that )(.+?) (?:do|mean|want|think|see|find)(?: .*)?", AskKind.OPEN),
          Rule("when (?:did|does|is|was|were|do) (.+)", AskKind.OPEN),
          Rule("(?:does it|did it|does the (?:text|book|letter|page)) say (.+)", AskKind.OPEN),
      )

  /** The kind of question [normalized] (Phrases.normalize) is, or null if it isn't one. */
  fun classify(normalized: String, followUps: Boolean = true): AskQuestion? {
    val text = normalized.trim().removeSuffix("?").trim()
    if (text.isEmpty()) return null
    for (rule in RULES) {
      val m = rule.regex.matchEntire(text) ?: continue
      if (rule.kind == AskKind.MORE || rule.kind == AskKind.NO) {
        if (!followUps || !FollowUps.allowed(rule.kind)) return null
        return AskQuestion(rule.kind)
      }
      var subject = m.groups.drop(1).lastOrNull { it != null && it.value.isNotBlank() }?.value?.trim()
      if (rule.kind == AskKind.FIND && text.startsWith("find me ")) return null // Watch for text's phrase
      subject = subject?.let(::cleanSubject)
      if (rule.kind == AskKind.WHAT && subject != null && NOT_TEXT.matches(subject)) return null
      if (rule.kind != AskKind.SPELL && rule.kind != AskKind.RECAP && rule.kind != AskKind.OPEN && subject.isNullOrEmpty()) return null
      return AskQuestion(rule.kind, subject?.takeIf { it.isNotEmpty() }, rule.lastTime)
    }
    return null
  }

  private fun cleanSubject(s: String): String =
      s.trim()
          .removePrefix("the word ").removePrefix("the name ")
          .removeSuffix(" again").removeSuffix(" please")
          .trim(' ', '\'', '"')

  /** An Ask command if [normalized] is a question about the text; [original] is kept as asked. */
  fun parse(normalized: String, original: String): GlobalCommand.Ask? {
    val q = classify(normalized) ?: return null
    return GlobalCommand.Ask(question = original.trim(), subject = q.subject)
  }

  /**
   * True if [transcript] (a partial result while reading) is already a whole question, so the book
   * reader can stop reading before the recogniser finishes (barge-in). Follow-ups don't count.
   */
  fun isQuestion(transcript: String): Boolean = classify(Phrases.normalize(transcript), followUps = false) != null
}
