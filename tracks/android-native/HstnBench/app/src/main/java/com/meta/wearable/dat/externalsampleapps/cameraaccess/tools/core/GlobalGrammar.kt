// GlobalGrammar - what the user can say in every tool
//
// Each tool has its own grammar for its own commands (book/VoiceCommands, tools/mail/MailGrammar,
// ...). ToolHub tries the open tool's grammar first and this one second, so a tool can give a
// phrase its own meaning ("read" in the book reader). This file covers three things:
//
//  1. Opening another tool from inside any tool: "read my mail", "what is this letter" -> mail;
//     "watch for 42", "tell me when you see exit" -> watch (target "42" / "exit"); "scan this",
//     "what's this product", "read the label" -> labels; "light detector", "is the light on" ->
//     light; "what colour is this" -> light in colour mode; "open the book reader", "read a book"
//     -> book. Each tool's own phrases live in its grammar file (MailGrammar.opens, ...), so a
//     feature agent can add synonyms without touching this file. They're tried in [OPENERS] order.
//  2. Questions about text that was just read ("what does ephemeral mean", "who is Mr. Bennet",
//     "what happened last time"), parsed by tools/ask/AskGrammar and answered by AskAboutText.
//  3. Commands every tool understands: pause/stop, carry on, repeat, faster/slower/speed, help,
//     battery, close.
//
// Same style as the book reader's grammar: ordered regex rules over normalised text (Phrases),
// fillers dropped, and room chatter parses to nothing. Pure Kotlin, JVM-tested (GlobalGrammarTest).

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core

import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ask.AskGrammar
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.labels.LabelsGrammar
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.light.LightGrammar
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.mail.MailGrammar
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.watch.WatchGrammar

sealed interface GlobalCommand {
  /** Stop talking now; the tool keeps its place. */
  data object Pause : GlobalCommand

  /** Carry on after a pause. */
  data object Resume : GlobalCommand

  /** Say the last thing again. */
  data object Repeat : GlobalCommand

  data class Faster(val step: Float = STEP) : GlobalCommand

  data class Slower(val step: Float = STEP) : GlobalCommand

  /** Exact speech rate, 1.0 = normal. */
  data class SetRate(val rate: Float) : GlobalCommand

  /** What you can say here. */
  data object Help : GlobalCommand

  /** Glasses and phone battery. */
  data object Battery : GlobalCommand

  /** Leave the tool. */
  data object Close : GlobalCommand

  /** Open another tool (or the same one with a new argument), keeping the glasses session. */
  data class Open(val request: ToolRequest) : GlobalCommand

  /**
   * A question about text that was just read. [question] is what the user said (address and
   * punctuation as heard); [subject] is the word or name asked about, when there is one.
   */
  data class Ask(val question: String, val subject: String? = null) : GlobalCommand

  companion object {
    const val STEP = 0.25f
    const val BIG_STEP = 0.5f
  }
}

/** One tool's "open me" phrases: normalised text and light text in, a request out. */
typealias ToolOpener = (normalized: String, light: String) -> ToolRequest?

object GlobalGrammar {

  /** Book reader phrases. The other tools' are in their own grammar files. */
  fun bookOpens(normalized: String, @Suppress("UNUSED_PARAMETER") light: String): ToolRequest? =
      if (BOOK_OPEN.matches(normalized)) ToolRequest(ToolId.BOOK) else null

  private val BOOK_OPEN =
      Regex(
          "^(?:(?:open|start|go to|switch to)(?: (?:the|my))? book(?: reader)?|(?:the )?book reader|" +
              "read (?:a|my|the) book|(?:go )?back to (?:the |my )?book|book mode)$",
      )

  /**
   * Tried in this order. Watch comes first because everything after "watch for" is its argument;
   * colour comes before light inside LightGrammar.
   */
  val OPENERS: List<ToolOpener> =
      listOf(
          WatchGrammar::opens,
          MailGrammar::opens,
          LabelsGrammar::opens,
          LightGrammar::opens,
          ::bookOpens,
      )

  private class Rule(pattern: String, val build: (MatchResult) -> GlobalCommand?) {
    val regex = Regex("^(?:$pattern)$")
  }

  private const val NUM = Phrases.NUM

  private val RULES: List<Rule> =
      listOf(
          Rule("(?:close|exit|quit|leave)(?: (?:the|this))?(?: (?:book|reader|book reader|app|tool|mail|mail reader|label reader|labels|light detector|watch|watch for text))?|goodbye|bye|i'?m done(?: here)?|that'?s (?:all|enough)(?: for (?:now|today))?") {
            GlobalCommand.Close
          },
          Rule("(?:(?:set |change )?(?:the )?(?:speed|rate|speech rate) (?:to |at )?$NUM(?: times| x)?|(?:talk |speak |read |go )?(?:at )?$NUM ?(?:times|x)(?: speed)?|$NUM speed)") { m ->
            val raw = m.groupValues.drop(1).firstOrNull { it.isNotEmpty() } ?: return@Rule null
            Phrases.parseNumber(raw)?.let { GlobalCommand.SetRate(it) }
          },
          Rule("(?:(?:back to )?normal speed|(?:reset|normal) (?:the )?(?:speed|rate)|regular speed)") {
            GlobalCommand.SetRate(1f)
          },
          Rule("(?:(?:much|a lot|way) faster|speed up a lot|much quicker)") {
            GlobalCommand.Faster(GlobalCommand.BIG_STEP)
          },
          Rule("(?:(?:much|a lot|way) slower|slow down a lot|much more slowly)") {
            GlobalCommand.Slower(GlobalCommand.BIG_STEP)
          },
          Rule("(?:(?:a )?(?:bit |little |little bit )?(?:faster|quicker)|speed (?:it )?up(?: a bit)?|(?:go|talk|speak|read) faster|hurry(?: up)?|too slow)") {
            GlobalCommand.Faster()
          },
          Rule("(?:(?:a )?(?:bit |little |little bit )?(?:slower|more slowly)|slow (?:it )?down(?: a bit)?|(?:go|talk|speak|read) slower|too fast)") {
            GlobalCommand.Slower()
          },
          Rule("(?:battery|batteries|battery level|how(?:'s| is| are) (?:the |my )?(?:battery|batteries)|how much battery(?: is left| do i have| have i got)?|check (?:the )?battery|is the battery (?:ok|low))") {
            GlobalCommand.Battery
          },
          Rule("(?:help|what can i say|what do i say|what are (?:the|my) (?:commands|options)|commands|options|how does this work)") {
            GlobalCommand.Help
          },
          Rule("(?:repeat(?: that| it)?|say (?:that|it) again|again|once more|pardon(?: me)?|sorry|what\\??|what did (?:it|you|that) say|i didn'?t (?:catch|get|hear) that|come again)") {
            GlobalCommand.Repeat
          },
          Rule("(?:stop|stop (?:it|talking|there)|pause|pause (?:it|there)|wait|wait (?:a (?:sec|second|moment|minute)|there)|(?:hold|hang) on(?: a (?:sec|second|moment|minute))?|hold it|quiet|be quiet|shush|shh+|hush|one (?:sec|second|moment|minute)|(?:just )?a (?:sec|second|moment|minute)|enough)") {
            GlobalCommand.Pause
          },
          Rule("(?:go on|go ahead|carry on|keep going|continue|resume|unpause|start|begin|i'?m ready|ready)") {
            GlobalCommand.Resume
          },
      )

  /** The global command in [transcript], or null if there isn't one. */
  fun parse(transcript: String): GlobalCommand? {
    val text = Phrases.normalize(transcript)
    if (text.isEmpty()) return null
    val light = Phrases.light(transcript).replace(Phrases.ANY_ADDRESS, "").trim()
    for (opener in OPENERS) opener(text, light)?.let { return GlobalCommand.Open(it) }
    AskGrammar.parse(text, transcript)?.let { return it }
    for (rule in RULES) {
      val m = rule.regex.matchEntire(text) ?: continue
      rule.build(m)?.let { return it }
    }
    return null
  }

  /** True if [transcript] is only a stop-talking command, so a tool can act on a partial result. */
  fun isBargeIn(transcript: String): Boolean = parse(transcript) == GlobalCommand.Pause
}
