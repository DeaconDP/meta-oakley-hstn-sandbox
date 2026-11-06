// LetterModel - one photographed page of a letter (or envelope), as OCR saw it
//
// Like the book's OcrPage, but it keeps what the mail reader needs and the book doesn't: which
// ML Kit block each line came from (letters are laid out in blocks: letterhead, address, date,
// paragraphs, a table of charges) and the confidence of each word and each character, so the money
// rule can refuse an amount when any one digit is unsure. MailOcr builds it from ML Kit; tests
// build it by hand. Coordinates are image pixels, origin top-left. Pure Kotlin, no Android.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.mail

import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.Box

/**
 * One word. [confidence] 0..1 or null if unknown; [symbolConfidences] one per character of [text]
 * when the engine gives them (empty otherwise).
 */
data class LetterWord(
    val text: String,
    val confidence: Float? = null,
    val symbolConfidences: List<Float> = emptyList(),
)

/** One line, from block number [block]. [words] may be empty (then [confidence] is all we know). */
data class LetterLine(
    val text: String,
    val box: Box,
    val block: Int,
    val confidence: Float? = null,
    val words: List<LetterWord> = emptyList(),
) {
  /**
   * The lowest confidence of any character in [start, end) of [text], from the most detailed
   * level available: characters, then words, then the line. Null if the engine gave none.
   */
  fun minConfidence(start: Int, end: Int, digitsOnly: Boolean = false): Float? {
    if (words.isEmpty()) return confidence
    var cursor = 0
    var lowest: Float? = null
    var anyWord = false
    for (w in words) {
      val at = text.indexOf(w.text, cursor)
      if (at < 0) return confidence // words don't line up with the text: fall back to the line
      cursor = at + w.text.length
      val ws = at
      val we = at + w.text.length
      if (we <= start || ws >= end) continue
      anyWord = true
      val c: Float? =
          if (w.symbolConfidences.size == w.text.length) {
            var m: Float? = null
            for (i in maxOf(ws, start) until minOf(we, end)) {
              val ch = text[i]
              if (digitsOnly && !ch.isDigit()) continue
              val s = w.symbolConfidences[i - ws]
              m = if (m == null) s else minOf(m, s)
            }
            m ?: w.confidence
          } else {
            w.confidence
          }
      if (c != null) lowest = if (lowest == null) c else minOf(lowest, c)
    }
    return if (anyWord) lowest ?: confidence else confidence
  }
}

/** A photographed page: its size and lines in engine order. */
data class LetterScan(val width: Int, val height: Int, val lines: List<LetterLine>) {
  val text: String
    get() = lines.joinToString("\n") { it.text }
}
