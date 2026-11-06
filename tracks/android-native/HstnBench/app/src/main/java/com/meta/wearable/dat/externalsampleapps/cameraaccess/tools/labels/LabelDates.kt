// LabelDates - finding best-before, use-by and expiry dates in label text
//
// "When does it expire?" reads the date out as a date ("12 March 2027") and says if it has passed.
// Labels print dates in many ways, so this looks for a date keyword (BEST BEFORE, BBE, BB, USE BY,
// EXP, EXPIRY, DISPLAY UNTIL, SELL BY...) and then for a date just after it, on the same line or the
// next: 12/03/27, 12.03.2027, 2027-03-12, 12 MAR, 12MAR27, March 12, 2027, MAR 2027, 03 2027,
// 03/27, 2027-03. Numbers are read day first (UK and EU labels) unless that's impossible. A day and
// month with no year get the year that puts the date nearest today, and the year isn't spoken. Full
// dates with no keyword are reported too, as "a date". "Best before: see top of pack" is reported
// as where to look. Pure Kotlin (java.time only), JVM-tested.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.labels

import java.time.LocalDate
import java.time.YearMonth

enum class DateKind(val spoken: String) {
  BEST_BEFORE("Best before"),
  USE_BY("Use by"),
  EXPIRY("Expiry date"),
  DISPLAY_UNTIL("Display until"),
  SELL_BY("Sell by"),
  /** A full date with no keyword next to it. */
  UNLABELLED("There's a date:"),
}

/** A date found on a label. [day] is null for month-only dates ("best before end 03 2027"). */
data class LabelDate(
    val kind: DateKind,
    val year: Int,
    val month: Int,
    val day: Int?,
    /** No year was printed; [year] is the nearest one to today. */
    val yearGuessed: Boolean = false,
    /** "Best before end" / month-only: the date means the end of that month. */
    val endOfMonth: Boolean = false,
) {
  /** The last day the date covers. */
  val lastDay: LocalDate
    get() = if (day != null) LocalDate.of(year, month, day) else YearMonth.of(year, month).atEndOfMonth()

  fun isPast(today: LocalDate): Boolean = lastDay.isBefore(today)

  /** "12 March 2027", "12 March" (no year printed), "the end of March 2027", "March 2027". */
  fun spoken(): String {
    val m = MONTH_NAMES[month - 1]
    return when {
      day != null && yearGuessed -> "$day $m"
      day != null -> "$day $m $year"
      endOfMonth -> "the end of $m $year"
      else -> "$m $year"
    }
  }

  companion object {
    val MONTH_NAMES =
        listOf(
            "January", "February", "March", "April", "May", "June", "July", "August", "September",
            "October", "November", "December",
        )
  }
}

/** What [LabelDates.find] saw. [elsewhere] is where the label says the date is ("top", "lid"). */
data class DateFindings(val dates: List<LabelDate>, val keywordWithoutDate: DateKind?, val elsewhere: String?)

object LabelDates {

  private const val MON =
      "(JANUARY|FEBRUARY|MARCH|APRIL|JUNE|JULY|AUGUST|SEPTEMBER|SEPT|OCTOBER|NOVEMBER|DECEMBER|" +
          "JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)"

  private class Keyword(val kind: DateKind, val regex: Regex)

  // Longest first, so "BEST BEFORE END" wins over "BEST BEFORE", "EXPIRY DATE" over "EXP".
  private val KEYWORDS =
      listOf(
          Keyword(DateKind.BEST_BEFORE, Regex("BEST\\s*BEFORE\\s*END(?:\\s*OF)?|\\bBBE\\b")),
          Keyword(DateKind.BEST_BEFORE, Regex("BEST\\s*BEFORE|BEST\\s*BY|\\bB\\.?B\\b\\.?")),
          Keyword(DateKind.USE_BY, Regex("USE\\s*BY|USE\\s*BEFORE|CONSUME\\s*BY|ENJOY\\s*BY")),
          Keyword(DateKind.EXPIRY, Regex("EXPIRY\\s*DATE|EXPIRATION\\s*DATE|EXPIRY|EXPIRES|EXPIRATION|\\bEXP\\b\\.?")),
          Keyword(DateKind.DISPLAY_UNTIL, Regex("DISPLAY\\s*UNTIL")),
          Keyword(DateKind.SELL_BY, Regex("SELL\\s*BY")),
      )

  private val SEE = Regex("^SEE\\s+(?:THE\\s+)?(TOP|BASE|BOTTOM|LID|SIDE|BACK|FRONT|CAP|END|NECK|SEAL|SHOULDER|CRIMP|CARTON|BOX)")
  private val GAP = Regex("^[\\s:.,\\-–]*(?:(?:DATE|ON|IS)\\b[\\s:.,\\-]*)*")

  /** A matched date: its parts and how many characters it used. */
  private class Parsed(val date: LabelDate, val length: Int)

  /**
   * All dates in [text] (any case; OCR lines joined with newlines), keyword dates first, in the
   * order they appear. [today] decides the year for dates printed without one.
   */
  fun find(text: String, today: LocalDate): DateFindings {
    val up = text.uppercase().replace('’', '\'')
    val dates = mutableListOf<LabelDate>()
    val used = mutableListOf<IntRange>()
    var keywordWithoutDate: DateKind? = null
    var elsewhere: String? = null

    val hits =
        KEYWORDS.flatMap { k -> k.regex.findAll(up).map { it to k } }
            .sortedWith(compareBy({ it.first.range.first }, { -it.first.value.length }))
    var lastEnd = -1
    for ((m, k) in hits) {
      if (m.range.first <= lastEnd) continue // inside a longer keyword already taken
      lastEnd = m.range.last
      val end = m.value.contains("END") || m.value.trim() == "BBE"
      val after = m.range.last + 1
      val gap = GAP.find(up.substring(after))!!.value.length
      val start = after + gap
      val window = up.substring(start, minOf(up.length, start + 40))
      SEE.find(window)?.let {
        elsewhere = elsewhere ?: it.groupValues[1].lowercase()
        continue
      }
      val parsed = parseAt(window, k.kind, end, today, labelled = true)
      if (parsed != null) {
        dates += parsed.date
        used += start until start + parsed.length
        lastEnd = maxOf(lastEnd, start + parsed.length - 1)
      } else {
        keywordWithoutDate = keywordWithoutDate ?: k.kind
      }
    }

    // Full dates with no keyword: only unambiguous forms with a year, at word boundaries.
    for (m in Regex("(?<![0-9A-Z])(?=[0-9A-Z])").findAll(up)) {
      val i = m.range.first
      if (used.any { i in it }) continue
      val window = up.substring(i, minOf(up.length, i + 40))
      val parsed = parseAt(window, DateKind.UNLABELLED, false, today, labelled = false) ?: continue
      if (dates.none { it.year == parsed.date.year && it.month == parsed.date.month && it.day == parsed.date.day }) {
        dates += parsed.date
      }
      used += i until i + parsed.length
    }
    return DateFindings(dates, if (dates.isEmpty()) keywordWithoutDate else null, elsewhere)
  }

  private val YMD = Regex("^(\\d{4})[-/. ](\\d{1,2})[-/. ](\\d{1,2})(?!\\d)")
  private val DMY = Regex("^(\\d{1,2})\\s?([/.\\-])\\s?(\\d{1,2})\\s?\\2\\s?(\\d{4}|\\d{2})(?!\\d)")
  private val DMY_SPACED = Regex("^(\\d{1,2}) (\\d{1,2}) (\\d{4}|\\d{2})(?!\\d)")
  private val D_MON_Y = Regex("^(\\d{1,2})(?:ST|ND|RD|TH)?\\s?[-/.]?\\s?$MON\\.?(?:\\s?[-/.,]?\\s?(\\d{4}|\\d{2})(?!\\d))?(?![A-Z])")
  private val MON_D_Y = Regex("^$MON\\.?\\s?(\\d{1,2})(?:ST|ND|RD|TH)?,?\\s(\\d{4})(?!\\d)")
  private val MON_Y = Regex("^$MON\\.?\\s?[-/.,]?\\s?(\\d{4}|\\d{2})(?!\\d)")
  private val Y_M = Regex("^(\\d{4})[-/.](\\d{1,2})(?!\\d)")
  private val M_YYYY = Regex("^(\\d{1,2})\\s?[-/. ]\\s?(\\d{4})(?!\\d)")
  private val NN_NN = Regex("^(\\d{1,2})\\s?[-/.]\\s?(\\d{1,2})(?![\\d/.\\-])")

  private fun parseAt(w: String, kind: DateKind, end: Boolean, today: LocalDate, labelled: Boolean): Parsed? {
    YMD.find(w)?.let { m ->
      val (y, mo, d) = m.destructured
      date(kind, y.toInt(), mo.toInt(), d.toInt())?.let { return Parsed(it, m.value.length) }
    }
    DMY.find(w)?.let { m ->
      val a = m.groupValues[1].toInt()
      val b = m.groupValues[3].toInt()
      val y = year(m.groupValues[4])
      // Day first unless the second number can't be a month.
      val dt = if (b > 12 && a <= 12) date(kind, y, a, b) else date(kind, y, b, a)
      dt?.let { return Parsed(it, m.value.length) }
    }
    if (labelled) {
      DMY_SPACED.find(w)?.let { m ->
        val (d, mo, y) = m.destructured
        date(kind, year(y), mo.toInt(), d.toInt())?.let { return Parsed(it, m.value.length) }
      }
    }
    D_MON_Y.find(w)?.let { m ->
      val d = m.groupValues[1].toInt()
      val mo = month(m.groupValues[2])
      val y = m.groupValues[3]
      if (y.isNotEmpty()) {
        date(kind, year(y), mo, d)?.let { return Parsed(it, m.value.length) }
      } else if (labelled) {
        guessYear(kind, mo, d, today)?.let { return Parsed(it, m.value.length) }
      }
    }
    MON_D_Y.find(w)?.let { m ->
      date(kind, m.groupValues[3].toInt(), month(m.groupValues[1]), m.groupValues[2].toInt())
          ?.let { return Parsed(it, m.value.length) }
    }
    if (!labelled) return null
    MON_Y.find(w)?.let { m ->
      val mo = month(m.groupValues[1])
      val n = m.groupValues[2]
      // "MAR 27": a year for expiry and best-before-end dates, otherwise the 27th.
      if (n.length == 4 || end || kind == DateKind.EXPIRY) {
        return Parsed(LabelDate(kind, year(n), mo, null, endOfMonth = true), m.value.length)
      }
      guessYear(kind, mo, n.toInt(), today)?.let { return Parsed(it, m.value.length) }
    }
    Y_M.find(w)?.let { m ->
      val mo = m.groupValues[2].toInt()
      if (mo in 1..12) return Parsed(LabelDate(kind, m.groupValues[1].toInt(), mo, null, endOfMonth = true), m.value.length)
    }
    M_YYYY.find(w)?.let { m ->
      val mo = m.groupValues[1].toInt()
      if (mo in 1..12) return Parsed(LabelDate(kind, m.groupValues[2].toInt(), mo, null, endOfMonth = true), m.value.length)
    }
    NN_NN.find(w)?.let { m ->
      val a = m.groupValues[1].toInt()
      val b = m.groupValues[2].toInt()
      // "03/27": month and year when the second can't be a month or it's an expiry date;
      // otherwise day and month ("BB 12/03"), year guessed.
      if (a in 1..12 && (b > 12 || end || kind == DateKind.EXPIRY)) {
        return Parsed(LabelDate(kind, 2000 + b, a, null, endOfMonth = true), m.value.length)
      }
      guessYear(kind, b, a, today)?.let { return Parsed(it, m.value.length) }
    }
    return null
  }

  private fun year(s: String): Int = if (s.length == 2) 2000 + s.toInt() else s.toInt()

  private fun month(s: String): Int =
      when (s.take(3)) {
        "JAN" -> 1; "FEB" -> 2; "MAR" -> 3; "APR" -> 4; "MAY" -> 5; "JUN" -> 6
        "JUL" -> 7; "AUG" -> 8; "SEP" -> 9; "OCT" -> 10; "NOV" -> 11; else -> 12
      }

  private fun valid(y: Int, m: Int, d: Int): Boolean =
      y in 1990..2100 && m in 1..12 && d in 1..YearMonth.of(y, m).lengthOfMonth()

  private fun date(kind: DateKind, y: Int, m: Int, d: Int): LabelDate? =
      if (valid(y, m, d)) LabelDate(kind, y, m, d) else null

  /** A day and month with no year: the year that puts it nearest [today]. */
  private fun guessYear(kind: DateKind, m: Int, d: Int, today: LocalDate): LabelDate? {
    if (m !in 1..12) return null
    val best =
        (today.year - 1..today.year + 1)
            .filter { valid(it, m, d) }
            .minByOrNull { kotlin.math.abs(LocalDate.of(it, m, d).toEpochDay() - today.toEpochDay()) }
            ?: return null
    return LabelDate(kind, best, m, d, yearGuessed = true)
  }

  /**
   * What to say for "when does it expire": the first date (and a second of another kind), said as
   * dates, and whether each has passed. Null when nothing was found, so the caller can ask the user
   * to turn the pack. "The label says the date is on the top" when the label points elsewhere.
   */
  fun answer(f: DateFindings, today: LocalDate): String? {
    if (f.dates.isEmpty()) {
      f.elsewhere?.let { return "The label says the date is on the $it. Turn it so I can see the $it, then ask again." }
      f.keywordWithoutDate?.let {
        return "I can see ${it.spoken.lowercase()}, but I can't make out the date. Hold it a little closer and ask again."
      }
      return null
    }
    val labelled = f.dates.filter { it.kind != DateKind.UNLABELLED }
    val chosen = (labelled.ifEmpty { f.dates }).let { list ->
      val first = list.first()
      listOfNotNull(first, list.drop(1).firstOrNull { it.kind != first.kind })
    }
    return chosen.joinToString(" ") { d ->
      val head = "${d.kind.spoken} ${d.spoken()}."
      val tail =
          when {
            d.isPast(today) -> " That date has already passed."
            d.lastDay == today -> " That's today."
            else -> ""
          }
      head + tail
    }
  }
}
