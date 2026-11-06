// LetterLayout - reading order for a letter page, from OCR block geometry
//
// A letter isn't a book page: a letterhead, two address blocks side by side, a right-aligned date,
// a table of charges with labels on the left and amounts on the right, then paragraphs and a
// signature. So this works on ML Kit's blocks instead of the book's column layout:
//   1. Table rows: an amount or a date (or a value after "Label:") on the right of the same row is joined to
//      its label on the left: "Standing charge £12.30", so it's read as one line, not as a list of
//      labels followed by a list of numbers.
//   2. Blocks are read top to bottom; blocks side by side (two address blocks) left first.
//   3. A block of short lines (an address) is read as one sentence with commas; a block of long
//      lines is a paragraph, with words hyphenated across line ends rejoined (book PageLayout).
// Pure Kotlin.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.mail

import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.Box
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.PageLayout

/** Lines of one block, in order, with its box. [isShortLines] when it reads like an address. */
data class LetterBlock(val lines: List<LetterLine>, val isShortLines: Boolean) {
  val box: Box
    get() = lines.map { it.box }.reduce(Box::union)

  val text: String
    get() = lines.joinToString("\n") { it.text }
}

data class LaidOutLetter(
    val scan: LetterScan,
    val blocks: List<LetterBlock>,
    /** What "read it all" speaks, one entry per paragraph. */
    val paragraphs: List<String>,
    /** Median line height on the page: the body text size. */
    val bodyHeight: Float,
) {
  val lines: List<LetterLine>
    get() = blocks.flatMap { it.lines }
}

object LetterLayout {

  private val DATE_LABEL =
      Regex("\\b(?:due|date|by|before|on|deadline|instalment|payment|appointment|expires?)\\s*:?\\s*$", RegexOption.IGNORE_CASE)

  fun layout(scan: LetterScan): LaidOutLetter {
    val lines = scan.lines.filter { it.text.isNotBlank() }
    if (lines.isEmpty()) return LaidOutLetter(scan, emptyList(), emptyList(), 0f)
    val bodyHeight = PageLayout.median(lines.map { it.box.height })
    val joined = joinTableRows(lines)
    val textLeft = joined.minOf { it.box.left }
    val textRight = joined.maxOf { it.box.right }
    val textWidth = (textRight - textLeft).coerceAtLeast(1f)

    val blocks =
        joined
            .groupBy { it.block }
            .values
            .flatMap { splitAtGaps(it.sortedBy { l -> l.box.top }, bodyHeight) }
            .map { group ->
              val short = group.count { it.box.width < textWidth * 0.55f }
              LetterBlock(group, isShortLines = group.size >= 2 && short * 10 >= group.size * 7)
            }
    val ordered = order(blocks)
    return LaidOutLetter(scan, ordered, ordered.map(::paragraph).filter { it.isNotBlank() }, bodyHeight)
  }

  /** Joins a right-hand value (an amount, or anything after a "Label:") to its label on the same row. */
  internal fun joinTableRows(lines: List<LetterLine>): List<LetterLine> {
    val out = lines.toMutableList()
    fun isMoney(t: String) = LetterText.money(t).let { m -> m.isNotEmpty() && t.length - m.sumOf { it.raw.length } <= 6 }
    fun isDate(t: String) = LetterText.dates(t).let { d -> d.size == 1 && t.length - d[0].raw.length <= 4 }
    for (value in lines.filter { isMoney(it.text.trim()) || isDate(it.text.trim()) }) {
      if (value !in out) continue
      val label = rowNeighbourOnLeft(out, value) ?: continue
      if (LetterText.money(label.text).isNotEmpty() || LetterText.dates(label.text).isNotEmpty()) continue
      // A date joins only a label that asks for one ("First instalment due"), never an address
      // line that happens to sit level with a right-aligned letter date.
      if (!isMoney(value.text.trim()) && !DATE_LABEL.containsMatchIn(label.text)) continue
      merge(out, label, value)
    }
    // "Account number:" | "1234 5678", "Payment due:" | "24 November 2026".
    for (label in out.toList()) {
      if (label !in out || !label.text.trimEnd().endsWith(":")) continue
      val value = rowNeighbourOnRight(out, label) ?: continue
      merge(out, label, value)
    }
    return out
  }

  private fun merge(out: MutableList<LetterLine>, label: LetterLine, value: LetterLine) {
    val at = out.indexOf(label)
    out[at] =
        LetterLine(
            text = label.text.trimEnd() + " " + value.text.trim(),
            box = label.box.union(value.box),
            block = label.block,
            confidence = listOfNotNull(label.confidence, value.confidence).minOrNull(),
            words = if (label.words.isNotEmpty() && value.words.isNotEmpty()) label.words + value.words else emptyList(),
        )
    out.remove(value)
  }

  private fun sameRow(a: Box, b: Box): Boolean {
    val overlap = minOf(a.bottom, b.bottom) - maxOf(a.top, b.top)
    return overlap >= 0.5f * minOf(a.height, b.height)
  }

  private fun rowNeighbourOnLeft(lines: List<LetterLine>, of: LetterLine): LetterLine? =
      lines.filter { it !== of && it.box.right <= of.box.left + 2f && sameRow(it.box, of.box) }.maxByOrNull { it.box.right }

  private fun rowNeighbourOnRight(lines: List<LetterLine>, of: LetterLine): LetterLine? =
      lines.filter { it !== of && it.box.left >= of.box.right - 2f && sameRow(it.box, of.box) }.minByOrNull { it.box.left }

  /** A block with a big vertical gap inside it is two blocks (ML Kit sometimes merges them). */
  private fun splitAtGaps(lines: List<LetterLine>, bodyHeight: Float): List<List<LetterLine>> {
    val out = mutableListOf<MutableList<LetterLine>>()
    for (l in lines) {
      val last = out.lastOrNull()?.last()
      if (last == null || l.box.top - last.box.bottom > bodyHeight * 1.2f) out += mutableListOf(l) else out.last() += l
    }
    return out
  }

  /** Top to bottom; of blocks side by side (overlapping rows), the left one first. */
  internal fun order(blocks: List<LetterBlock>): List<LetterBlock> {
    val rest = blocks.toMutableList()
    val out = mutableListOf<LetterBlock>()
    while (rest.isNotEmpty()) {
      var pick = rest.minBy { it.box.top }
      val beside =
          rest.filter {
            it !== pick && it.box.right <= pick.box.left + 4f &&
                minOf(it.box.bottom, pick.box.bottom) - maxOf(it.box.top, pick.box.top) > 0.3f * minOf(it.box.height, pick.box.height)
          }
      beside.minByOrNull { it.box.left }?.let { pick = it }
      out += pick
      rest.remove(pick)
    }
    return out
  }

  /** One block as spoken text: an address with commas and a full stop, a paragraph rejoined. */
  internal fun paragraph(block: LetterBlock): String {
    val texts = block.lines.map { it.text.trim() }.filter { it.isNotEmpty() }
    if (block.isShortLines) {
      val joined = texts.joinToString(", ") { it.trimEnd(',') }
      return if (joined.last() in ".!?:") joined else "$joined."
    }
    val sb = StringBuilder()
    for (t in texts) {
      // A table row ending in an amount or a date is its own sentence: "Standing charge £12.30."
      val endsInValue =
          LetterText.money(t).lastOrNull()?.let { it.range.last >= t.length - 1 } == true ||
              LetterText.dates(t).lastOrNull()?.let { it.range.last >= t.length - 1 } == true
      // (Short lines only: a long body line can end in a date mid-sentence.)
      PageLayout.joinLine(sb, if (endsInValue && texts.size > 1 && t.length <= 50) "$t." else t)
    }
    return sb.toString()
  }
}
