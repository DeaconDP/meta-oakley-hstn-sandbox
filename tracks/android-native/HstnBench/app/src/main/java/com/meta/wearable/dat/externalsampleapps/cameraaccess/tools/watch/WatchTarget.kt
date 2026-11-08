// WatchTarget - what the user asked us to watch for, made ready for matching
//
// The user says it ("watch for 42", "look out for platform three", "find Boots", "the 73 bus") and
// the recogniser writes it down in its own way, so this turns it into a short list of tokens: whole
// numbers ("42"), codes that mix digits and letters ("12B"), and words ("platform", "boots").
// Number words become digits when the whole target is a number ("forty two", "four two", "one oh
// one") or when they follow a sign word such as platform, gate or room ("platform three"), but not
// inside ordinary words ("one way" stays words). Words around a bus number that a bus front doesn't
// show ("bus", "number", "route", "the") are dropped. A number followed by a single letter ("12 b")
// becomes a code. [display] is what we say back ("42", "platform 3", "12B").
// Pure Kotlin (no Android imports), JVM-tested.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.watch

/** One token of a target or of recognised text. */
enum class TokenKind {
  /** Digits only: matched exactly ("42" never matches "421"). */
  NUMBER,
  /** Digits and letters together ("12B", "A4"): matched exactly, ignoring case. */
  CODE,
  /** Letters only: matched loosely (OCR noise, case, a missing letter). */
  WORD,
}

data class TargetToken(val text: String, val kind: TokenKind)

data class WatchTarget(val tokens: List<TargetToken>) {
  /** What we say back: "42", "platform 3", "12B". */
  val display: String
    get() = tokens.joinToString(" ") { if (it.kind == TokenKind.CODE) it.text.uppercase() else it.text }

  /** A single whole number ("42"): the kind that gets "I see 24, not 42" near misses. */
  val isSingleNumber: Boolean
    get() = tokens.size == 1 && tokens[0].kind == TokenKind.NUMBER

  companion object {
    /** Words that introduce a number on a sign: number words after them become digits. */
    private val CUES =
        setOf(
            "platform", "gate", "room", "stop", "stand", "bay", "terminal", "floor", "level",
            "exit", "door", "track", "pier", "zone", "aisle", "bus", "route", "number", "no",
            "flat", "unit", "block", "lift", "carriage", "coach", "seat", "row",
        )

    /** Words a bus front doesn't show; dropped when the target has a number in it. */
    private val NUMBER_NOISE = setOf("bus", "number", "no", "route", "the", "a", "an")

    private val LEADING = setOf("the", "a", "an", "some", "sign", "signs")

    /** [raw] is what the user said after "watch for". Null if nothing usable is left. */
    fun parse(raw: String): WatchTarget? {
      var words =
          raw.lowercase()
              .replace('’', '\'')
              .replace(Regex("[^a-z0-9' ]"), " ")
              .split(' ')
              .map { it.trim('\'') }
              .filter { it.isNotEmpty() }
      while (words.isNotEmpty() && words.first() in LEADING) words = words.drop(1)
      while (words.isNotEmpty() && words.last() in setOf("please", "sign")) words = words.dropLast(1)
      if (words.isEmpty()) return null

      words = numberWordsToDigits(words)
      if (words.any { it.all(Char::isDigit) }) {
        val kept = words.filter { it !in NUMBER_NOISE }
        if (kept.isNotEmpty()) words = kept
      }
      words = joinNumberAndLetter(words)

      val tokens =
          words.map { w ->
            val clean = w.replace("'", "")
            TargetToken(clean, kindOf(clean))
          }.filter { it.text.isNotEmpty() }
      return if (tokens.isEmpty()) null else WatchTarget(tokens)
    }

    fun kindOf(token: String): TokenKind =
        when {
          token.all(Char::isDigit) -> TokenKind.NUMBER
          token.any(Char::isDigit) -> TokenKind.CODE
          else -> TokenKind.WORD
        }

    /** "forty two" -> "42" when the whole target is a number, or after a cue word. */
    private fun numberWordsToDigits(words: List<String>): List<String> {
      NumberWords.parse(words)?.let { return listOf(it) }
      val out = mutableListOf<String>()
      var i = 0
      while (i < words.size) {
        val afterCue = i > 0 && words[i - 1] in CUES
        if (afterCue && NumberWords.isNumberWord(words[i])) {
          var j = i
          while (j < words.size && NumberWords.isNumberWord(words[j])) j++
          // Longest run that parses, from i.
          var end = j
          var value: String? = null
          while (end > i && value == null) {
            value = NumberWords.parse(words.subList(i, end))
            if (value == null) end--
          }
          if (value != null) {
            out += value
            i = end
            continue
          }
        }
        out += words[i]
        i++
      }
      return out
    }

    /** "12 b" -> "12b" (a room or gate code). */
    private fun joinNumberAndLetter(words: List<String>): List<String> {
      val out = mutableListOf<String>()
      for (w in words) {
        val last = out.lastOrNull()
        if (last != null && last.all(Char::isDigit) && w.length == 1 && w[0].isLetter()) {
          out[out.size - 1] = last + w
        } else {
          out += w
        }
      }
      return out
    }
  }
}

/** Spoken numbers to digits: "forty two" = 42, "four two" = 42, "one oh one" = 101. */
object NumberWords {
  private val DIGITS =
      mapOf(
          "zero" to 0, "oh" to 0, "o" to 0, "nought" to 0, "one" to 1, "two" to 2, "three" to 3,
          "four" to 4, "five" to 5, "six" to 6, "seven" to 7, "eight" to 8, "nine" to 9,
      )
  private val TEENS =
      mapOf(
          "ten" to 10, "eleven" to 11, "twelve" to 12, "thirteen" to 13, "fourteen" to 14,
          "fifteen" to 15, "sixteen" to 16, "seventeen" to 17, "eighteen" to 18, "nineteen" to 19,
      )
  private val TENS =
      mapOf(
          "twenty" to 20, "thirty" to 30, "forty" to 40, "fourty" to 40, "fifty" to 50,
          "sixty" to 60, "seventy" to 70, "eighty" to 80, "ninety" to 90,
      )

  fun isNumberWord(w: String): Boolean =
      w in DIGITS || w in TEENS || w in TENS || w == "hundred" || w == "and" || w.all(Char::isDigit)

  /** The digits for the whole of [words], or null if they aren't exactly one number. */
  fun parse(words: List<String>): String? {
    if (words.isEmpty()) return null
    if (words.size == 1 && words[0].all(Char::isDigit)) return words[0]
    // Digit by digit: "four two", "one oh one" (at least two digit words, nothing else).
    if (words.size >= 2 && words.all { it in DIGITS }) return words.joinToString("") { DIGITS.getValue(it).toString() }
    if (words.any { it == "o" || it == "oh" }) return null
    // Composed: [units hundred [and]] [tens] [units|teens], or a lone number word.
    var i = 0
    var total = 0
    var any = false
    fun peek() = words.getOrNull(i)
    val first = peek()
    if (first != null && first in DIGITS && words.getOrNull(1) == "hundred") {
      total += DIGITS.getValue(first) * 100
      i += 2
      any = true
      if (peek() == "and") i++
    } else if (first == "hundred") {
      total += 100
      i++
      any = true
      if (peek() == "and") i++
    }
    when (val w = peek()) {
      in TEENS -> {
        total += TEENS.getValue(w!!)
        i++
        any = true
      }
      in TENS -> {
        total += TENS.getValue(w!!)
        i++
        any = true
        val u = peek()
        if (u != null && u in DIGITS && DIGITS.getValue(u) > 0) {
          total += DIGITS.getValue(u)
          i++
        }
      }
      in DIGITS -> {
        total += DIGITS.getValue(w!!)
        i++
        any = true
      }
    }
    return if (any && i == words.size) total.toString() else null
  }
}
