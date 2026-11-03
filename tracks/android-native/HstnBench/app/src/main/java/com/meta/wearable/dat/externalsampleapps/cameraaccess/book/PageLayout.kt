// PageLayout - turns OCR lines into readable book text
//
// The OCR engine returns lines with boxes in roughly top-to-bottom order. A camera pointed at an
// open book also sees the facing page, the running header and the page number. This file:
//  1. splits a two-page spread at the gutter (the widest vertical gap near the middle that almost
//     no line crosses) and orders left page, then right page;
//  2. puts each page's lines in reading order (rows top to bottom, segments left to right);
//  3. pulls off the running header and page number (short top/bottom lines, digit or roman
//     numerals, set apart from the body by a larger gap);
//  4. merges lines into paragraphs (a big gap, an indent, or a short line ending a sentence starts
//     a new one) and rejoins words hyphenated across line ends and across the two pages.
// Pure Kotlin so it runs as a JVM unit test. Two-column textbooks and footnotes are out of scope.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.book

import kotlin.math.abs

enum class PageSide {
  SINGLE,
  LEFT,
  RIGHT,
}

data class LaidOutPage(
    val side: PageSide,
    val header: String?,
    val pageNumber: String?,
    val paragraphs: List<String>,
    /** The first body line is indented, so it starts a new paragraph rather than continuing one. */
    val startsWithIndent: Boolean,
)

data class PageLayoutResult(val pages: List<LaidOutPage>) {

  val isEmpty: Boolean
    get() = pages.all { it.paragraphs.isEmpty() }

  /**
   * What to read, in order. Without furniture, body paragraphs are joined across the gutter (a word
   * hyphenated from the left page onto the right page is rejoined, and a paragraph that runs over
   * continues). With furniture, each page starts with "Page N." and its running header.
   */
  fun readingParagraphs(includeFurniture: Boolean): List<String> {
    val out = mutableListOf<String>()
    var lastBody = -1
    for (page in pages) {
      var paragraphs = page.paragraphs
      val hasFurniture = page.header != null || page.pageNumber != null
      if (includeFurniture && hasFurniture) {
        // The announcement goes between the pages, but a word broken across the gutter is still
        // rejoined: move the right page's first word back onto the left page's last paragraph.
        if (lastBody >= 0 && PageLayout.endsWithBrokenWord(out[lastBody]) && paragraphs.isNotEmpty()) {
          val first = paragraphs[0]
          val space = first.indexOf(' ')
          val word = if (space < 0) first else first.substring(0, space)
          val sb = StringBuilder(out[lastBody])
          PageLayout.joinLine(sb, word)
          out[lastBody] = sb.toString()
          val rest = if (space < 0) "" else first.substring(space + 1)
          paragraphs = listOf(rest).filter { it.isNotBlank() } + paragraphs.drop(1)
        }
        page.pageNumber?.let { out += "Page $it." }
        page.header?.let { out += "$it." }
      }
      val canContinue = !(includeFurniture && hasFurniture)
      PageLayout.appendParagraphs(out, paragraphs, page.startsWithIndent, canContinue)
      if (paragraphs.isNotEmpty()) lastBody = out.size - 1
    }
    return out
  }

  /** Body text only, paragraphs separated by blank lines. Used for display, dedup and scoring. */
  fun bodyText(): String = readingParagraphs(includeFurniture = false).joinToString("\n\n")

  fun text(includeFurniture: Boolean): String =
      readingParagraphs(includeFurniture).joinToString("\n\n")
}

object PageLayout {

  data class Options(
      /** Fraction of the text extent, either side of centre, searched for a gutter. */
      val gutterSearch: Float = 0.2f,
      /** At most this fraction of lines may cross the gutter (spread-wide titles, OCR merges). */
      val maxGutterCrossFraction: Float = 0.08f,
      /** A paragraph break is a line pitch at least this many times the median pitch. */
      val paragraphGapFactor: Float = 1.45f,
      /** A furniture line sits at least this many times the median pitch away from the body. */
      val furnitureGapFactor: Float = 1.5f,
      val maxFurnitureWords: Int = 8,
  )

  private val HYPHENS = setOf('-', '­', '‐', '‑', '¬')
  private val DASHES = setOf('—', '–')
  private val ROMAN = Regex("^(m{0,3})(cm|cd|d?c{0,3})(xc|xl|l?x{0,3})(ix|iv|v?i{0,3})$")
  private val NUMBER_TOKEN = Regex("^[\\[(\\-–—.·•]*([0-9]{1,4}|[ivxlcdmIVXLCDM]{1,7})[\\])\\-–—.·•]*$")
  private val HEADING_WORDS = Regex("^(chapter|part|book|prologue|epilogue|contents)\\b", RegexOption.IGNORE_CASE)

  fun layout(page: OcrPage, options: Options = Options()): PageLayoutResult {
    val lines = page.lines.filter { it.text.isNotBlank() }
    if (lines.isEmpty()) return PageLayoutResult(emptyList())
    val halves = splitSpread(lines, options)
    return PageLayoutResult(halves.map { (side, sideLines) -> layoutPage(side, sideLines, options) })
  }

  // MARK: - Spread split

  /** Returns the gutter x if [lines] look like a two-page spread, else null. */
  fun findGutter(lines: List<OcrLine>, options: Options = Options()): Float? {
    if (lines.size < 6) return null
    val left = lines.minOf { it.box.left }
    val right = lines.maxOf { it.box.right }
    val width = right - left
    if (width <= 0f) return null
    val from = left + width * (0.5f - options.gutterSearch)
    val to = left + width * (0.5f + options.gutterSearch)
    val steps = 80
    val crossings =
        IntArray(steps + 1) { i ->
          val x = from + (to - from) * i / steps
          lines.count { it.box.left < x && it.box.right > x }
        }
    val best = crossings.min()
    if (best > maxOf(1, (lines.size * options.maxGutterCrossFraction).toInt())) return null
    // Longest run of minimal-crossing samples; its centre is the gutter.
    var bestStart = -1
    var bestLen = 0
    var i = 0
    while (i <= steps) {
      if (crossings[i] == best) {
        var j = i
        while (j + 1 <= steps && crossings[j + 1] == best) j++
        if (j - i + 1 > bestLen) {
          bestLen = j - i + 1
          bestStart = i
        }
        i = j + 1
      } else {
        i++
      }
    }
    val gutter = from + (to - from) * (bestStart + (bestLen - 1) / 2f) / steps
    val leftCount = lines.count { it.box.centerX < gutter }
    val rightCount = lines.size - leftCount
    val minSide = maxOf(3, lines.size / 4)
    return if (leftCount >= minSide && rightCount >= minSide) gutter else null
  }

  private fun splitSpread(
      lines: List<OcrLine>,
      options: Options,
  ): List<Pair<PageSide, List<OcrLine>>> {
    val gutter = findGutter(lines, options) ?: return listOf(PageSide.SINGLE to lines)
    val (leftLines, rightLines) = lines.partition { it.box.centerX < gutter }
    return listOf(PageSide.LEFT to leftLines, PageSide.RIGHT to rightLines)
  }

  // MARK: - One page

  /** Lines in reading order, with segments that share a row merged into one line. */
  fun readingOrder(lines: List<OcrLine>): List<OcrLine> {
    val sorted = lines.sortedBy { it.box.top }
    val rows = mutableListOf<MutableList<OcrLine>>()
    for (line in sorted) {
      val row =
          rows.lastOrNull()?.takeIf { row ->
            val rowTop = row.minOf { it.box.top }
            val rowBottom = row.maxOf { it.box.bottom }
            val overlap = minOf(rowBottom, line.box.bottom) - maxOf(rowTop, line.box.top)
            overlap > 0.5f * minOf(rowBottom - rowTop, line.box.height)
          }
      if (row != null) row += line else rows += mutableListOf(line)
    }
    return rows.map { row ->
      if (row.size == 1) {
        row[0]
      } else {
        val ordered = row.sortedBy { it.box.left }
        OcrLine(
            text = ordered.joinToString(" ") { it.text.trim() },
            box = ordered.map { it.box }.reduce(Box::union),
            confidence = ordered.mapNotNull { it.confidence }.takeIf { it.isNotEmpty() }?.average()?.toFloat(),
        )
      }
    }
  }

  private fun layoutPage(side: PageSide, lines: List<OcrLine>, options: Options): LaidOutPage {
    val rows = readingOrder(lines).toMutableList()
    if (rows.isEmpty()) return LaidOutPage(side, null, null, emptyList(), false)
    val lineHeight = median(rows.map { it.box.height })
    val pitch = medianPitch(rows, lineHeight)

    var header: String? = null
    var pageNumber: String? = null

    // Top: up to two furniture rows (e.g. a page number on its own row above the running header).
    repeat(2) {
      if (rows.size < 2) return@repeat
      val first = rows[0]
      val gapBelow = rows[1].box.top - first.box.top
      when (val f = classifyFurniture(first, gapBelow, pitch, lineHeight, options)) {
        is Furniture.Number -> {
          pageNumber = pageNumber ?: f.number
          rows.removeAt(0)
        }
        is Furniture.Header -> {
          if (header == null) {
            header = f.text
            if (f.number != null) pageNumber = pageNumber ?: f.number
            rows.removeAt(0)
          }
        }
        null -> return@repeat
      }
    }
    // Bottom: a page number or a short footer line set apart from the body.
    if (rows.size >= 2) {
      val last = rows.last()
      val gapAbove = last.box.top - rows[rows.size - 2].box.top
      when (val f = classifyFurniture(last, gapAbove, pitch, lineHeight, options)) {
        is Furniture.Number -> {
          pageNumber = pageNumber ?: f.number
          rows.removeAt(rows.size - 1)
        }
        is Furniture.Header ->
            if (f.number != null) {
              pageNumber = pageNumber ?: f.number
              if (header == null) header = f.text
              rows.removeAt(rows.size - 1)
            }
        null -> Unit
      }
    }

    val (paragraphs, startsWithIndent) = buildParagraphs(rows, lineHeight, pitch, options)
    return LaidOutPage(side, header, pageNumber, paragraphs, startsWithIndent)
  }

  private sealed interface Furniture {
    data class Number(val number: String) : Furniture

    data class Header(val text: String, val number: String?) : Furniture
  }

  private fun pageNumberOf(token: String): String? {
    val m = NUMBER_TOKEN.matchEntire(token.trim()) ?: return null
    val core = m.groupValues[1]
    if (core.all { it.isDigit() }) return core
    val lower = core.lowercase()
    // Roman numerals only in lower or upper case (not "Mix"), and only well-formed ones.
    if (core != lower && core != core.uppercase()) return null
    return if (lower.isNotEmpty() && ROMAN.matches(lower)) core else null
  }

  private fun classifyFurniture(
      line: OcrLine,
      gapToBody: Float,
      pitch: Float,
      lineHeight: Float,
      options: Options,
  ): Furniture? {
    val text = line.text.trim()
    pageNumberOf(text)?.let { number ->
      // A lone digit row is a page number. A lone roman numeral could be a word ("mix", "I"), so
      // it must also be set apart from the body.
      return if (number.all { it.isDigit() } || gapToBody >= options.furnitureGapFactor * pitch) {
        Furniture.Number(number)
      } else {
        null
      }
    }
    val words = text.split(Regex("\\s+"))
    if (words.size > options.maxFurnitureWords + 1) return null
    // "12  THE TITLE" or "THE TITLE  13": a header carrying the page number.
    val leadingNumber = pageNumberOf(words.first())?.takeIf { it.all(Char::isDigit) }
    val trailingNumber = pageNumberOf(words.last())?.takeIf { it.all(Char::isDigit) }
    if (words.size >= 2 && (leadingNumber != null || trailingNumber != null)) {
      val rest =
          (if (leadingNumber != null) words.drop(1) else words.dropLast(1)).joinToString(" ")
      if (rest.isNotEmpty() && rest.last() !in ".!?") {
        return Furniture.Header(rest, leadingNumber ?: trailingNumber)
      }
    }
    // A short, separated, body-sized line with no sentence ending: a running header. Chapter
    // headings are content, so they are kept.
    if (
        words.size <= options.maxFurnitureWords &&
            gapToBody >= options.furnitureGapFactor * pitch &&
            line.box.height <= 1.15f * lineHeight &&
            text.last() !in ".!?\"”'’" &&
            !HEADING_WORDS.containsMatchIn(text)
    ) {
      return Furniture.Header(text, null)
    }
    return null
  }

  private fun buildParagraphs(
      rows: List<OcrLine>,
      lineHeight: Float,
      pitch: Float,
      options: Options,
  ): Pair<List<String>, Boolean> {
    if (rows.isEmpty()) return emptyList<String>() to false
    val bodyLeft = percentile(rows.map { it.box.left }, 0.2f)
    val bodyRight = percentile(rows.map { it.box.right }, 0.8f)
    val bodyWidth = (bodyRight - bodyLeft).coerceAtLeast(1f)
    val indent = 0.8f * lineHeight
    fun isIndented(line: OcrLine) = line.box.left - bodyLeft > indent

    val paragraphs = mutableListOf<String>()
    var current = StringBuilder(rows[0].text.trim())
    for (i in 1 until rows.size) {
      val prev = rows[i - 1]
      val line = rows[i]
      val lineText = line.text.trim()
      val bigGap = line.box.top - prev.box.top > options.paragraphGapFactor * pitch
      val newIndent = isIndented(line) && abs(prev.box.left - bodyLeft) < 0.5f * lineHeight
      val prevShort =
          prev.box.right < bodyRight - 0.15f * bodyWidth &&
              prev.text.trimEnd().lastOrNull()?.let { it in ".!?:\"”’)" } == true
      if (bigGap || newIndent || prevShort) {
        paragraphs += current.toString()
        current = StringBuilder(lineText)
      } else {
        joinLine(current, lineText)
      }
    }
    paragraphs += current.toString()
    return paragraphs to isIndented(rows[0])
  }

  /** Appends [next] to [sb], rejoining a word hyphenated across the line end. */
  internal fun joinLine(sb: StringBuilder, next: String) {
    if (next.isEmpty()) return
    val n = sb.length
    if (n == 0) {
      sb.append(next)
      return
    }
    val last = sb[n - 1]
    val beforeLast = if (n >= 2) sb[n - 2] else ' '
    when {
      last in HYPHENS && beforeLast.isLetter() -> {
        if (next.first().isLowerCase()) {
          sb.setLength(n - 1) // "exam-" + "ple" -> "example"
        } else if (last != '-') {
          sb.setCharAt(n - 1, '-') // soft hyphen before a capital: keep a plain hyphen
        }
        sb.append(next)
      }
      last in DASHES -> sb.append(next)
      last == '-' && beforeLast.isDigit() && next.first().isDigit() -> sb.append(next) // "12-14"
      else -> sb.append(' ').append(next)
    }
  }

  /** True if [text] ends in a letter followed by a line-end hyphen, i.e. a word broken mid-way. */
  fun endsWithBrokenWord(text: String): Boolean {
    val t = text.trimEnd()
    return t.length >= 2 && t.last() in HYPHENS && t[t.length - 2].isLetter()
  }

  /**
   * Appends one page's [paragraphs] to [out]. If [canContinue] and the previous paragraph was left
   * mid-sentence (a broken word, or no sentence ending and this page doesn't start indented with a
   * capital), the first paragraph continues it.
   */
  internal fun appendParagraphs(
      out: MutableList<String>,
      paragraphs: List<String>,
      startsWithIndent: Boolean,
      canContinue: Boolean,
  ) {
    if (paragraphs.isEmpty()) return
    val prev = out.lastOrNull()
    val first = paragraphs.first()
    if (canContinue && prev != null && continuesParagraph(prev, first, startsWithIndent)) {
      val sb = StringBuilder(prev)
      joinLine(sb, first)
      out[out.size - 1] = sb.toString()
      out += paragraphs.drop(1)
    } else {
      out += paragraphs
    }
  }

  private fun continuesParagraph(prev: String, next: String, nextIndented: Boolean): Boolean {
    if (endsWithBrokenWord(prev)) return true
    if (nextIndented) return false
    val endsSentence = prev.trimEnd().lastOrNull()?.let { it in ".!?\"”’" } ?: true
    return !endsSentence && next.firstOrNull()?.isLowerCase() == true
  }

  // MARK: - Stats

  private fun medianPitch(rows: List<OcrLine>, lineHeight: Float): Float {
    val pitches =
        rows.zipWithNext { a, b -> b.box.top - a.box.top }
            .filter { it > 0.5f * lineHeight && it < 3f * lineHeight }
    return if (pitches.isEmpty()) 1.3f * lineHeight else median(pitches)
  }

  internal fun median(values: List<Float>): Float = percentile(values, 0.5f)

  internal fun percentile(values: List<Float>, p: Float): Float {
    if (values.isEmpty()) return 0f
    val sorted = values.sorted()
    val idx = ((sorted.size - 1) * p).toInt().coerceIn(0, sorted.size - 1)
    return sorted[idx]
  }
}
