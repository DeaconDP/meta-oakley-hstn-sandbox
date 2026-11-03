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
// EchoGuard handles the other half of hands-free listening: the glasses' (or phone's) mic also hears
// the book being read aloud. A transcript that is just something we said recently is ignored.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.book

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

  private val FILLERS =
      listOf(
          "please", "um", "umm", "uh", "er", "erm", "okay", "ok", "alright", "right", "so",
          "can you", "could you", "would you", "will you", "i want you to", "i'd like you to",
          "just", "now", "thanks", "thank you",
      )

  private val ADDRESS = Regex("^(hey |ok |okay )?(book )?reader\\b ?")

  private val NUMBER_WORDS =
      mapOf(
          "zero" to 0f, "half" to 0.5f, "one" to 1f, "two" to 2f, "three" to 3f, "four" to 4f,
          "five" to 5f, "six" to 6f, "seven" to 7f, "eight" to 8f, "nine" to 9f, "ten" to 10f,
          "a" to 1f, "an" to 1f, "single" to 1f, "double" to 2f, "triple" to 3f, "couple" to 2f,
          "few" to 3f,
      )

  private const val NUM =
      "(\\d+(?:\\.\\d+)?|(?:zero|one|two|three|four|five|six|seven|eight|nine|ten|half|a|an|" +
          "double|triple|couple|few)(?: (?:point|and a half|and) ?(?:\\d|zero|one|two|three|" +
          "four|five|six|seven|eight|nine|half)?)?)"

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
          Rule("(?:close|exit|quit|leave)(?: the)?(?: book| reader| book reader| app)?|goodbye|bye|i'?m done(?: reading)?|that'?s enough for (?:now|today)|stop reading for (?:now|today)") {
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
  fun normalize(transcript: String): String {
    var t = transcript.lowercase()
        .replace('’', '\'')
        .replace(Regex("[^a-z0-9.' ]"), " ")
        .replace(Regex("(?<![0-9])\\.|\\.(?![0-9])"), " ")
        .replace(Regex("\\s+"), " ")
        .trim()
    t = t.replace(ADDRESS, "").trim()
    for (f in FILLERS) t = t.replace(Regex("(^| )${Regex.escape(f)}(?= |$)"), " ")
    return t.replace(Regex("\\s+"), " ").trim()
  }

  /** "1.5", "one point five", "one and a half", "two", "double", "half". Null if not a number. */
  fun parseNumber(raw: String): Float? {
    val s = raw.trim()
    s.toFloatOrNull()?.let { return it }
    val parts = s.split(' ')
    val head = NUMBER_WORDS[parts[0]] ?: return null
    if (parts.size == 1) return head
    val rest = parts.drop(1).joinToString(" ")
    return when {
      rest == "and a half" -> head + 0.5f
      rest.startsWith("point ") -> {
        val tail = rest.removePrefix("point ").trim()
        val digit = tail.toIntOrNull() ?: NUMBER_WORDS[tail]?.toInt() ?: return null
        if (digit !in 0..9) return null
        head + digit / 10f
      }
      rest.startsWith("and ") -> {
        val tail = rest.removePrefix("and ").trim()
        if (tail == "half") head + 0.5f else null
      }
      else -> null
    }
  }

  /** True if [transcript] is only a stop-talking command, so it can act on a partial result. */
  fun isBargeIn(transcript: String): Boolean = parse(transcript) == VoiceCommand.Pause
}

/**
 * Remembers what the reader is saying, or said a moment ago, so the mic hearing the book (or our own
 * replies) isn't taken as the user talking.
 *
 * A transcript is an echo when its words appear as a run inside something that is being spoken
 * right now. That catches a command word read out from the book ("Stop!" cried Holmes), including
 * as a partial result. In the [tailMs] after speech ends (recogniser latency), only fragments of
 * [MIN_TAIL_WORDS]+ words count: echoes arrive as phrases, while a user answering a prompt ("Say
 * read to start" → "read") says one or two words and must be heard. After that nothing is filtered.
 */
class EchoGuard(private val tailMs: Long = 2_000L, private val maxEntries: Int = 4) {

  private companion object {
    const val MIN_TAIL_WORDS = 3
  }

  private class Spoken(val words: List<String>, var endMs: Long = Long.MAX_VALUE)

  private val recent = ArrayDeque<Spoken>()

  /** Call when speech of [text] starts. */
  @Synchronized
  fun spoke(text: String, nowMs: Long) {
    val words = words(text)
    if (words.isEmpty()) return
    // Speech is sequential: whatever was playing before has ended.
    recent.lastOrNull()?.let { if (it.endMs == Long.MAX_VALUE) it.endMs = nowMs }
    recent.addLast(Spoken(words))
    while (recent.size > maxEntries) recent.removeFirst()
  }

  /** Call when speech finishes or is cut off. */
  @Synchronized
  fun finished(nowMs: Long) {
    recent.lastOrNull()?.let { if (it.endMs == Long.MAX_VALUE) it.endMs = nowMs }
  }

  @Synchronized
  fun clear() = recent.clear()

  @Synchronized
  fun isEcho(transcript: String, nowMs: Long): Boolean {
    val heard = words(transcript)
    if (heard.isEmpty()) return false
    return recent.any { s ->
      val speaking = s.endMs == Long.MAX_VALUE
      val inTail = !speaking && nowMs - s.endMs <= tailMs && heard.size >= MIN_TAIL_WORDS
      (speaking || inTail) && containsRun(s.words, heard)
    }
  }

  /** [heard] appears as a contiguous run in [spoken], allowing one misheard word in four. */
  private fun containsRun(spoken: List<String>, heard: List<String>): Boolean {
    val allowedMisses = heard.size / 4
    for (start in spoken.indices) {
      if (spoken[start] != heard[0] && allowedMisses == 0) continue
      var misses = 0
      for ((k, w) in heard.withIndex()) {
        if (spoken.getOrNull(start + k) != w) misses++
        if (misses > allowedMisses) break
      }
      if (misses <= allowedMisses) return true
    }
    return false
  }

  private fun words(text: String): List<String> =
      text.lowercase().replace('’', '\'').split(Regex("[^a-z0-9']+")).filter { it.isNotEmpty() }
}
