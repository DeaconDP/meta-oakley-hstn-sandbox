// VoiceCommands - what the reader understands when the user talks to it
//
// Voice is the default way to drive the book reader: a blind reader can't find buttons on a phone
// screen while holding a book. Understanding stays on-device (no cloud): a recogniser gives us text,
// and this file turns natural, forgiving phrasing into one of a small set of commands. "Hang on",
// "wait", "stop" and "shush" all mean Pause; "carry on", "keep going" and "read" mean Resume;
// "say that again" means Repeat; "a bit faster" means Faster.
//
// Rules are tried in order, so specific phrases come before the short words inside them
// ("stop detecting page turns" before "stop", "read that again" before "read"). Fillers ("please",
// "um", "can you") and an optional address ("reader, ...") are dropped first.
//
// Normalising text and reading numbers is shared with every tool (tools/core/Phrases.kt), and the
// echo guard that ignores the book coming back through the mic is tools/core/EchoGuard.kt.
// Commands every tool understands (switching tools, "what does X mean") are in
// tools/core/GlobalGrammar.kt; the book reader tries its own grammar first, then that one.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.book

import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.Phrases

sealed interface VoiceCommand {
  /** Stop talking now, keep the place. */
  data object Pause : VoiceCommand

  /** Start, or carry on from where it paused. */
  data object Resume : VoiceCommand

  /** "I've turned the page": capture and read the page in view. */
  data object NextPage : VoiceCommand

  /** Say the current sentence again. */
  data object Repeat : VoiceCommand

  /** Go back [sentences] sentences and read on from there. */
  data class Back(val sentences: Int = 1) : VoiceCommand

  /** Back to the start of the current paragraph. */
  data object BackParagraph : VoiceCommand

  /** Read the current page again from the top. */
  data object FromTop : VoiceCommand

  /** Speed up by [step] (×). */
  data class Faster(val step: Float = STEP) : VoiceCommand

  /** Slow down by [step] (×). */
  data class Slower(val step: Float = STEP) : VoiceCommand

  /** Set an exact speech rate, 1.0 = normal. */
  data class SetRate(val rate: Float) : VoiceCommand

  /** Page, sentence and speed, spoken. */
  data object WhereAmI : VoiceCommand

  /** What you can say. */
  data object Help : VoiceCommand

  /** Glasses and phone battery, spoken. */
  data object Battery : VoiceCommand

  /** Read page numbers and running headers, or skip them. */
  data class ReadFurniture(val enabled: Boolean) : VoiceCommand

  /** Detect page turns from the camera, or wait for "next page". */
  data class AutoTurn(val enabled: Boolean) : VoiceCommand

  /** Leave the reader; the bookmark is kept. */
  data object Close : VoiceCommand

  companion object {
    const val STEP = 0.25f
    const val BIG_STEP = 0.5f
  }
}

object VoiceCommands {

  private val ADDRESS = Regex("^(hey |ok |okay )?(book )?reader\\b ?")

  private const val NUM = Phrases.NUM

  private class Rule(pattern: String, val build: (MatchResult) -> VoiceCommand?) {
    val regex = Regex("^(?:$pattern)$")
  }

  private val NEG = "(?:don'?t|do not|stop|skip|no|never|without|turn off|switch off|disable)"

  private val RULES: List<Rule> =
      listOf(
          // Settings first: they contain words like "stop", "read" and "turn".
          Rule("$NEG (?:reading |saying |read |say )?(?:the )?(?:page numbers?|headers?|headings?|running heads?)(?: and (?:the )?(?:page numbers?|headers?|headings?))?") {
            VoiceCommand.ReadFurniture(false)
          },
          Rule("(?:read|say|include|turn on|switch on|enable) (?:the )?(?:page numbers?|headers?|headings?|running heads?)(?: and (?:the )?(?:page numbers?|headers?|headings?))?(?: too| as well)?") {
            VoiceCommand.ReadFurniture(true)
          },
          Rule("(?:$NEG (?:detecting |watching for |listening for )?(?:automatic )?page turns?(?: detection)?|(?:automatic page turns?|page turn detection|auto turn) off|i'?ll tell you when i turn(?: the page)?|wait for me to say next page)") {
            VoiceCommand.AutoTurn(false)
          },
          Rule("(?:(?:detect|watch for|turn on|switch on|enable) (?:automatic )?page turns?(?: detection)?(?: automatically)?|(?:automatic page turns?|page turn detection|auto turn) on)") {
            VoiceCommand.AutoTurn(true)
          },
          // Leaving.
          Rule("(?:close|exit|quit|leave)(?: the)?(?: book| reader| book reader)?|goodbye|bye|i'?m done(?: reading)?|that'?s enough for (?:now|today)|stop reading for (?:now|today)") {
            VoiceCommand.Close
          },
          // Speed.
          Rule("(?:(?:set |change )?(?:the )?(?:speed|rate|speech rate) (?:to |at )?$NUM(?: times| x)?|(?:read |go )?(?:at )?$NUM ?(?:times|x)(?: speed)?|$NUM speed)") { m ->
            val raw = m.groupValues.drop(1).firstOrNull { it.isNotEmpty() } ?: return@Rule null
            parseNumber(raw)?.let { VoiceCommand.SetRate(it) }
          },
          Rule("(?:(?:back to )?normal speed|(?:reset|normal) (?:the )?(?:speed|rate)|regular speed)") {
            VoiceCommand.SetRate(1f)
          },
          Rule("(?:(?:much|a lot|way) faster|speed up a lot|much quicker)") {
            VoiceCommand.Faster(VoiceCommand.BIG_STEP)
          },
          Rule("(?:(?:much|a lot|way) slower|slow down a lot|much more slowly)") {
            VoiceCommand.Slower(VoiceCommand.BIG_STEP)
          },
          Rule("(?:(?:a )?(?:bit |little |little bit )?(?:faster|quicker)|speed (?:it )?up(?: a bit)?|go faster|read faster|hurry(?: up)?|too slow)") {
            VoiceCommand.Faster()
          },
          Rule("(?:(?:a )?(?:bit |little |little bit )?(?:slower|more slowly)|slow (?:it )?down(?: a bit)?|go slower|read slower|too fast)") {
            VoiceCommand.Slower()
          },
          // Where am I / help.
          Rule("(?:where am i|where are we|what page(?: am i on| are we on| is this)?|how far (?:am i|are we|have i got|have we got)|status)") {
            VoiceCommand.WhereAmI
          },
          Rule("(?:battery|batteries|battery level|how(?:'s| is| are) (?:the |my )?(?:battery|batteries)|how much battery(?: is left| do i have| have i got)?|check (?:the )?battery|is the battery (?:ok|low))") {
            VoiceCommand.Battery
          },
          Rule("(?:help|what can i say|what do i say|what are (?:the|my) (?:commands|options)|commands|options|how does this work)") {
            VoiceCommand.Help
          },
          // Moving around the page.
          Rule("(?:(?:read|start)(?: (?:the|this))? page (?:again|from the (?:top|start|beginning))|(?:start |go |read )?(?:again )?from the (?:top|start|beginning)(?: of the page)?|(?:start|read) (?:the page )?over|start the page again)") {
            VoiceCommand.FromTop
          },
          Rule("(?:(?:go )?back (?:a|one|to the start of the) paragraph|(?:go )?back to the (?:start|beginning) of the paragraph|(?:read )?(?:the|that) (?:last )?paragraph again|previous paragraph)") {
            VoiceCommand.BackParagraph
          },
          Rule("(?:(?:go |skip )?back $NUM sentences?|(?:go |skip )?back $NUM)") { m ->
            val raw = m.groupValues.drop(1).firstOrNull { it.isNotEmpty() } ?: return@Rule null
            parseNumber(raw)?.toInt()?.takeIf { it in 1..20 }?.let { VoiceCommand.Back(it) }
          },
          Rule("(?:(?:go |skip )?back(?: a bit| a sentence| one sentence)?|previous sentence|last sentence|rewind)") {
            VoiceCommand.Back(1)
          },
          Rule("(?:repeat(?: that| it| the sentence| the last sentence)?|(?:say|read) (?:that|it) again|again|once more|pardon(?: me)?|sorry|what\\??|what did (?:it|you|that) say|i didn'?t (?:catch|get|hear) that|come again)") {
            VoiceCommand.Repeat
          },
          Rule("(?:next page|new page|(?:i'?ve |i have )?turned(?: the page| it| over)?|page turned|turn(?:ed)? over|done,? next page|read the next (?:page|one)|next one|ready for the next page)") {
            VoiceCommand.NextPage
          },
          // Pause and resume: the short words, last.
          Rule("(?:stop|stop (?:it|reading|talking|there)|pause|pause (?:it|reading|there)|wait|wait (?:a (?:sec|second|moment|minute)|there)|(?:hold|hang) on(?: a (?:sec|second|moment|minute))?|hold it|quiet|be quiet|shush|shh+|hush|one (?:sec|second|moment|minute)|(?:just )?a (?:sec|second|moment|minute)|enough)") {
            VoiceCommand.Pause
          },
          Rule("(?:read|read (?:it|this|the page|to me|on|the book|aloud)|start|start reading|go|go on|go ahead|carry on|keep going|keep reading|continue|continue reading|resume|play|unpause|let'?s go|let'?s start|begin|ready|i'?m ready|okay go|on you go)") {
            VoiceCommand.Resume
          },
      )

  /** The command in [transcript], or null if it isn't one. */
  fun parse(transcript: String): VoiceCommand? {
    val text = normalize(transcript)
    if (text.isEmpty()) return null
    for (rule in RULES) {
      val m = rule.regex.matchEntire(text) ?: continue
      rule.build(m)?.let { return it }
    }
    return null
  }

  /** Lowercase, punctuation out (apostrophes kept), address and fillers dropped, spaces collapsed. */
  fun normalize(transcript: String): String = Phrases.normalize(transcript, ADDRESS)

  /** "1.5", "one point five", "one and a half", "two", "double", "half". Null if not a number. */
  fun parseNumber(raw: String): Float? = Phrases.parseNumber(raw)

  /** True if [transcript] is only a stop-talking command, so it can act on a partial result. */
  fun isBargeIn(transcript: String): Boolean = parse(transcript) == VoiceCommand.Pause
}

