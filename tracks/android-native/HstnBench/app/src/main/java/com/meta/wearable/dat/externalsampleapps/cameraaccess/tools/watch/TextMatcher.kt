// TextMatcher - does this frame's text contain what we're watching for, and where?
//
// Works on the engine-neutral OcrPage (book/OcrModel), one line at a time. Each line is split into
// tokens: whole numbers, decimals ("4.2", "10:30"), codes ("42A") and words. The rules:
//  - Numbers are exact. "42" matches the token 42 anywhere in a line ("42 Victoria", "No. 42",
//    "Bus 42"), and a sign-word prefix stuck to it ("No42", "Platform3"), but never 421, 142, 4.2
//    or 42A. OCR's letter-for-digit slips inside a number are undone first ("4O" = 40, "1l" = 11).
//  - Codes ("12B") are exact, ignoring case; "12 B" split by OCR also matches.
//  - Words are loose: case and punctuation ignored, and a small edit distance allowed by length
//    (none up to 3 letters, 1 up to 7, 2 beyond), using book/TextDistance. Digits that OCR puts in
//    words are read as letters ("B00TS" = boots).
//  - Several tokens ("platform 3") must sit next to each other on one line, in order, or run
//    together in one OCR token ("PLATFORM3").
// The position is the matched characters' share of the line's box, so "42" at the left end of a
// wide bus-front line is placed left of the line's centre. Near misses ("I see 24, not 42") are for
// single-number targets only: the same digits with two swapped, or (3+ digits) one digit different.
// Pure Kotlin, JVM-tested.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.watch

import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.OcrPage
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.TextDistance

/** Where a match was: [x] is the horizontal centre, 0 = left edge of the frame, 1 = right edge. */
data class Spot(val text: String, val x: Float, val heightFraction: Float)

/** What one frame showed: the target (best sighting), or a near miss, or neither. */
data class FrameMatch(val hit: Spot?, val nearMiss: String?) {
  companion object {
    val NONE = FrameMatch(null, null)
  }
}

/** One token of recognised text. [start]/[end] are character offsets in the line. */
data class OcrToken(val text: String, val kind: OcrKind, val start: Int, val end: Int)

enum class OcrKind { NUMBER, DECIMAL, CODE, WORD }

object TextMatcher {

  private val TOKEN = Regex("\\d+(?:[.,:]\\d+)+|[\\p{L}\\p{N}'|]+")

  /** Prefixes OCR may run into a number: "No42", "Platform3". */
  private val NUMBER_PREFIXES =
      setOf("no", "nr", "num", "number", "bus", "route", "platform", "plat", "gate", "room", "stop", "stand", "bay")

  fun tokens(line: String): List<OcrToken> =
      TOKEN.findAll(line).mapNotNull { m ->
        val raw = m.value.replace("'", "")
        if (raw.isEmpty()) return@mapNotNull null
        val text = raw.lowercase()
        val kind =
            when {
              m.value.first().isDigit() && text.any { it == '.' || it == ',' || it == ':' } -> OcrKind.DECIMAL
              text.all(Char::isDigit) -> OcrKind.NUMBER
              text.any(Char::isDigit) -> {
                val asDigits = digitSlips(text)
                if (asDigits.all(Char::isDigit)) return@mapNotNull OcrToken(asDigits, OcrKind.NUMBER, m.range.first, m.range.last + 1)
                OcrKind.CODE
              }
              else -> OcrKind.WORD
            }
        OcrToken(text.replace("|", "l"), kind, m.range.first, m.range.last + 1)
      }.toList()

  /** Letters OCR reads in place of digits, inside something that has digits: O->0, I/l/|->1. */
  private fun digitSlips(t: String): String =
      t.map {
        when (it) {
          'o' -> '0'
          'i', 'l', '|' -> '1'
          else -> it
        }
      }.joinToString("")

  /** Digits OCR reads in place of letters, inside a word: 0->o, 1->l, 5->s. */
  private fun letterSlips(t: String): String =
      t.map {
        when (it) {
          '0' -> 'o'
          '1' -> 'l'
          '5' -> 's'
          else -> it
        }
      }.joinToString("")

  /** Edits allowed for a word of [length] letters. */
  fun allowedEdits(length: Int): Int =
      when {
        length <= 3 -> 0
        length <= 7 -> 1
        else -> 2
      }

  fun wordMatches(target: String, ocr: String): Boolean {
    val o = letterSlips(ocr)
    if (o == target) return true
    val allowed = allowedEdits(target.length)
    if (allowed == 0 || kotlin.math.abs(o.length - target.length) > allowed) return false
    return TextDistance.levenshtein(target.toList(), o.toList()) <= allowed
  }

  private fun stripZeros(s: String) = s.trimStart('0').ifEmpty { "0" }

  fun tokenMatches(t: TargetToken, o: OcrToken): Boolean =
      when (t.kind) {
        TokenKind.NUMBER ->
            when (o.kind) {
              OcrKind.NUMBER -> stripZeros(o.text) == stripZeros(t.text)
              OcrKind.CODE -> {
                // "No42", "Platform3": a known sign word stuck to the number.
                val m = Regex("^([a-z]+)(\\d+)$").find(o.text)
                m != null && m.groupValues[1] in NUMBER_PREFIXES && stripZeros(m.groupValues[2]) == stripZeros(t.text)
              }
              else -> false
            }
        TokenKind.CODE -> o.kind == OcrKind.CODE && codeMatches(t.text, o.text)
        TokenKind.WORD -> (o.kind == OcrKind.WORD || o.kind == OcrKind.CODE) && wordMatches(t.text, o.text)
      }

  /** A code compared position by position, undoing OCR slips: digit where the target has a digit. */
  private fun codeMatches(target: String, ocr: String): Boolean =
      target.length == ocr.length &&
          target.indices.all { i ->
            val t = target[i]
            val o = ocr[i]
            if (t.isDigit()) digitSlips(o.toString())[0] == t else letterSlips(o.toString())[0] == t
          }

  /** The character range of the target in [line], or null. */
  fun findInLine(target: WatchTarget, line: String): IntRange? {
    val toks = tokens(line)
    if (toks.isEmpty()) return null
    val n = target.tokens.size
    // In order, side by side.
    for (i in 0..toks.size - n) {
      if ((0 until n).all { k -> tokenMatches(target.tokens[k], toks[i + k]) }) {
        return toks[i].start until toks[i + n - 1].end
      }
    }
    // A code split by OCR: "12 B".
    if (n == 1 && target.tokens[0].kind == TokenKind.CODE) {
      for (i in 0 until toks.size - 1) {
        val a = toks[i]
        val b = toks[i + 1]
        if ((a.kind == OcrKind.NUMBER || a.kind == OcrKind.WORD) && a.text + b.text == target.tokens[0].text) {
          return a.start until b.end
        }
      }
    }
    // Several target tokens run together in one OCR token: "PLATFORM3".
    if (n >= 2) {
      val joined = target.tokens.joinToString("") { it.text }
      for (o in toks) if (joinedMatches(joined, o.text)) return o.start until o.end
    }
    // One long word split by OCR: "BO OTS".
    if (n == 1 && target.tokens[0].kind == TokenKind.WORD && target.tokens[0].text.length >= 5) {
      for (i in 0 until toks.size - 1) {
        if (toks[i].kind == OcrKind.WORD && toks[i + 1].kind == OcrKind.WORD &&
            toks[i].text + toks[i + 1].text == target.tokens[0].text) {
          return toks[i].start until toks[i + 1].end
        }
      }
    }
    return null
  }

  /** Digits exact, letters loose. */
  private fun joinedMatches(target: String, ocr: String): Boolean {
    val tDigits = target.filter(Char::isDigit)
    val oDigits = ocr.filter(Char::isDigit)
    if (tDigits != oDigits) return false
    val tLetters = target.filter { !it.isDigit() }
    val oLetters = ocr.filter { !it.isDigit() }
    if (tLetters.isEmpty()) return oLetters.isEmpty()
    return wordMatches(tLetters, oLetters)
  }

  /** Same length, not equal: two digits swapped, or (3+ digits) one digit different. */
  fun isNearMiss(target: String, seen: String): Boolean {
    if (seen.length != target.length || seen == target) return false
    val diff = target.indices.filter { target[it] != seen[it] }
    if (diff.size == 2 && target[diff[0]] == seen[diff[1]] && target[diff[1]] == seen[diff[0]]) return true
    return diff.size == 1 && target.length >= 3
  }

  /** The best sighting in [page] (the tallest, i.e. probably the nearest), or a near miss. */
  fun find(target: WatchTarget, page: OcrPage): FrameMatch {
    var best: Spot? = null
    var near: String? = null
    for (line in page.lines) {
      val range = findInLine(target, line.text)
      if (range != null) {
        val len = line.text.length.coerceAtLeast(1)
        val mid = (range.first + range.last + 1) / 2f / len
        val xPx = line.box.left + line.box.width * mid
        val spot =
            Spot(
                text = line.text.substring(range).trim(),
                x = (xPx / page.imageWidth).coerceIn(0f, 1f),
                heightFraction = line.box.height / page.imageHeight,
            )
        if (best == null || spot.heightFraction > best.heightFraction) best = spot
      } else if (near == null && target.isSingleNumber) {
        near = tokens(line.text).firstOrNull { it.kind == OcrKind.NUMBER && isNearMiss(target.tokens[0].text, it.text) }?.text
      }
    }
    return if (best != null) FrameMatch(best, null) else FrameMatch(null, near)
  }
}
