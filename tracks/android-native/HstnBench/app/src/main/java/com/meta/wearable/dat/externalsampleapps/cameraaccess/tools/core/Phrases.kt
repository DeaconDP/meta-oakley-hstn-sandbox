// Phrases - turning what the recogniser heard into text a grammar can match
//
// Every tool's grammar (book/VoiceCommands, tools/core/GlobalGrammar, tools/<id>/<Id>Grammar) works
// on the same normalised form: lower case, punctuation out (apostrophes and decimal points kept),
// an optional address dropped ("reader, ...", "glasses, ..."), filler words dropped ("please",
// "um", "can you", ...) and spaces collapsed. Numbers can be digits or words ("1.5", "one and a
// half", "double"). Lifted out of the book reader's VoiceCommands so all tools share one behaviour.
// Pure Kotlin, JVM-tested.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core

object Phrases {

  /** Words people add around a command that don't change it. */
  val FILLERS: List<String> =
      listOf(
          "please", "um", "umm", "uh", "er", "erm", "okay", "ok", "alright", "right", "so",
          "can you", "could you", "would you", "will you", "i want you to", "i'd like you to",
          "just", "now", "thanks", "thank you",
      )

  private val NUMBER_WORDS =
      mapOf(
          "zero" to 0f, "half" to 0.5f, "one" to 1f, "two" to 2f, "three" to 3f, "four" to 4f,
          "five" to 5f, "six" to 6f, "seven" to 7f, "eight" to 8f, "nine" to 9f, "ten" to 10f,
          "a" to 1f, "an" to 1f, "single" to 1f, "double" to 2f, "triple" to 3f, "couple" to 2f,
          "few" to 3f,
      )

  /** Regex group for a number, digits or words, for use inside grammar rules. */
  const val NUM =
      "(\\d+(?:\\.\\d+)?|(?:zero|one|two|three|four|five|six|seven|eight|nine|ten|half|a|an|" +
          "double|triple|couple|few)(?: (?:point|and a half|and) ?(?:\\d|zero|one|two|three|" +
          "four|five|six|seven|eight|nine|half)?)?)"

  /**
   * Addresses any tool accepts in front of a command: "glasses, ...", "hey app, ...". Only dropped
   * when something follows, so "book reader" on its own still names the tool.
   */
  val ANY_ADDRESS = Regex("^(hey |ok |okay )?(the )?(book reader|reader|glasses|app|assistant) (?=\\S)")

  /**
   * Lower case, punctuation out (apostrophes and decimal points kept), spaces collapsed. Words
   * are all still there, so arguments ("watch for the right exit") keep every word.
   */
  fun light(transcript: String): String =
      transcript.lowercase()
          .replace('’', '\'')
          .replace(Regex("[^a-z0-9.' ]"), " ")
          .replace(Regex("(?<![0-9])\\.|\\.(?![0-9])"), " ")
          .replace(Regex("\\s+"), " ")
          .trim()

  /** [light], then [address] and [fillers] dropped. What grammar rules match against. */
  fun normalize(
      transcript: String,
      address: Regex = ANY_ADDRESS,
      fillers: List<String> = FILLERS,
  ): String {
    var t = light(transcript)
    t = t.replace(address, "").trim()
    for (f in fillers) t = t.replace(Regex("(^| )${Regex.escape(f)}(?= |$)"), " ")
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

  /**
   * What follows [lead] (a regex for the command words) in [light] text, with polite words trimmed
   * off the end: after("watch for", "watch for the right exit please") = "the right exit". Uses the
   * light form so an argument keeps words that are fillers elsewhere ("right", "now").
   */
  fun after(lead: Regex, light: String): String? {
    val m = lead.find(light) ?: return null
    var rest = light.substring(m.range.last + 1).trim()
    rest = rest.replace(Regex("(?: (?:please|thanks|thank you|for me))+$"), "").trim()
    return rest.takeIf { it.isNotEmpty() }
  }

  /** Number of words in [transcript] (for "short enough to be a command" checks). */
  fun wordCount(transcript: String): Int = transcript.trim().split(Regex("\\s+")).count { it.isNotEmpty() }
}
