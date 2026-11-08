// LetterText - finding money, dates, postcodes and reference numbers in a line of letter text
//
// Fixed patterns, no guessing. Money: "£84.17", "€1,250", "$19.99", "84.17 GBP". A token that looks
// like money but has a letter where a digit should be ("£8O.17", "£1l.50": OCR confusing O/0 and
// l/1) is reported as unreadable, never corrected. Dates: "24 November 2026", "Nov 24, 2026",
// "24/11/2026" (UK order: day first), "2026-11-24". Reference numbers are spoken one character at
// a time ("1 2 3 4, 5 6 7 8"), so a TTS engine never says "twelve million...". Pure Kotlin.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.mail

/** An amount of money in minor units (pence, cents). */
data class Money(val currency: String, val minor: Long) {
  /** "£84.17", "£1,250", "€3.50". Whole amounts drop the ".00". */
  fun spoken(): String {
    val major = minor / 100
    val cents = minor % 100
    val grouped = "%,d".format(java.util.Locale.UK, major)
    return if (cents == 0L) "$currency$grouped" else "$currency$grouped.${"%02d".format(cents)}"
  }
}

/** One money-looking token in a line. [money] is null when a character isn't a digit. */
data class MoneyToken(val raw: String, val range: IntRange, val money: Money?, val credit: Boolean)

data class LetterDate(val day: Int, val month: Int, val year: Int, val raw: String, val range: IntRange) {
  fun spoken(): String = "$day ${LetterText.MONTHS[month - 1]} $year"
}

object LetterText {

  val MONTHS =
      listOf(
          "January", "February", "March", "April", "May", "June", "July", "August", "September",
          "October", "November", "December",
      )

  private const val MONTH =
      "(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|" +
          "sept?(?:ember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)"

  // Currency first. The body allows O/o/l/I/S/B so misread digits are caught, then rejected.
  private val MONEY_PREFIX =
      Regex("(?<![A-Za-z0-9])(£|\\$|€|GBP ?|EUR ?|USD ?)\\s?([0-9OoIlSB](?:[0-9OoIlSB]|,(?=[0-9OoIlSB]))*(?:\\.[0-9OoIlSB]{2})?)(?![0-9A-Za-z])(\\s?CR\\b)?")
  private val MONEY_SUFFIX =
      Regex("(?<![A-Za-z0-9£$€.,])(\\d[\\d,]*(?:\\.\\d{2})?) ?(GBP|EUR|USD|pounds|euros|dollars)\\b", RegexOption.IGNORE_CASE)
  private val GROUPED = Regex("\\d{1,3}(?:,\\d{3})*|\\d+")

  private val DATE_DMY =
      Regex("\\b(\\d{1,2})(?:st|nd|rd|th)?\\s+(?:of\\s+)?$MONTH\\.?,?\\s+(\\d{4})\\b", RegexOption.IGNORE_CASE)
  private val DATE_MDY =
      Regex("\\b$MONTH\\.?\\s+(\\d{1,2})(?:st|nd|rd|th)?,?\\s+(\\d{4})\\b", RegexOption.IGNORE_CASE)
  private val DATE_NUM = Regex("\\b(\\d{1,2})[/.](\\d{1,2})[/.](\\d{4}|\\d{2})\\b")
  private val DATE_ISO = Regex("\\b(\\d{4})-(\\d{2})-(\\d{2})\\b")

  val UK_POSTCODE = Regex("\\b[A-Z]{1,2}\\d[A-Z\\d]? ?\\d[A-Z]{2}\\b")
  private val US_ZIP = Regex("\\b[A-Z]{2} \\d{5}(?:-\\d{4})?\\b")

  fun money(line: String): List<MoneyToken> {
    val out = mutableListOf<MoneyToken>()
    for (m in MONEY_PREFIX.findAll(line)) {
      val symbol = when (m.groupValues[1].trim()) {
        "GBP" -> "£"
        "EUR" -> "€"
        "USD" -> "$"
        else -> m.groupValues[1].trim()
      }
      val body = m.groupValues[2]
      // "£1" followed by a word like "Off" etc. is still money; a lone "£S" isn't.
      if (body.none { it.isDigit() }) continue
      out += MoneyToken(m.value.trim(), m.range, parse(symbol, body), m.groupValues[3].isNotBlank())
    }
    for (m in MONEY_SUFFIX.findAll(line)) {
      if (out.any { it.range.first <= m.range.last && m.range.first <= it.range.last }) continue
      val symbol = when (m.groupValues[2].lowercase()) {
        "gbp", "pounds" -> "£"
        "eur", "euros" -> "€"
        else -> "$"
      }
      out += MoneyToken(m.value, m.range, parse(symbol, m.groupValues[1]), false)
    }
    return out.sortedBy { it.range.first }
  }

  /** Strict parse: digits, optional thousands commas, optional two decimals. Else null. */
  private fun parse(symbol: String, body: String): Money? {
    val parts = body.split('.')
    if (parts.size > 2) return null
    val whole = parts[0]
    if (!GROUPED.matches(whole)) return null
    val cents = if (parts.size == 2) parts[1].takeIf { it.length == 2 && it.all(Char::isDigit) } ?: return null else "00"
    return Money(symbol, whole.replace(",", "").toLong() * 100 + cents.toLong())
  }

  fun dates(line: String): List<LetterDate> {
    val out = mutableListOf<LetterDate>()
    fun add(d: Int, mo: Int, y: Int, m: MatchResult) {
      if (mo !in 1..12 || d !in 1..31) return
      if (out.any { it.range.first <= m.range.last && m.range.first <= it.range.last }) return
      out += LetterDate(d, mo, if (y < 100) 2000 + y else y, m.value, m.range)
    }
    for (m in DATE_DMY.findAll(line)) add(m.groupValues[1].toInt(), monthOf(m.groupValues[2]), m.groupValues[3].toInt(), m)
    for (m in DATE_MDY.findAll(line)) add(m.groupValues[2].toInt(), monthOf(m.groupValues[1]), m.groupValues[3].toInt(), m)
    for (m in DATE_ISO.findAll(line)) add(m.groupValues[3].toInt(), m.groupValues[2].toInt(), m.groupValues[1].toInt(), m)
    for (m in DATE_NUM.findAll(line)) add(m.groupValues[1].toInt(), m.groupValues[2].toInt(), m.groupValues[3].toInt(), m)
    return out.sortedBy { it.range.first }
  }

  private fun monthOf(word: String): Int {
    val w = word.lowercase().take(3)
    return MONTHS.indexOfFirst { it.lowercase().startsWith(w) } + 1
  }

  fun hasPostcode(line: String): Boolean = UK_POSTCODE.containsMatchIn(line) || US_ZIP.containsMatchIn(line)

  /**
   * A reference spoken character by character: "AB 1234-56" -> "A B, 1 2 3 4, 5 6". Groups (split
   * at spaces, dashes and slashes) are separated by commas so the voice pauses where the print does.
   */
  fun spellOut(value: String): String =
      value.trim()
          .split(Regex("[\\s\\-/]+"))
          .filter { it.isNotEmpty() }
          .joinToString(", ") { group -> group.filter { it.isLetterOrDigit() }.uppercase().toCharArray().joinToString(" ") }

  /**
   * Text made safe to read aloud: long digit runs (account numbers, phone numbers starting with 0)
   * are spaced out so they're read digit by digit. Money, dates and years are left alone.
   */
  fun forSpeech(text: String): String =
      text
          .replace(Regex("(?<![£$€\\d.,/])\\b0\\d{2,}(?: \\d{3,})*\\b(?![.,]\\d)")) { spellOut(it.value) }
          .replace(Regex("(?<![£$€\\d.,/])\\b\\d{5,}\\b(?![.,]\\d)")) { spellOut(it.value) }
}
