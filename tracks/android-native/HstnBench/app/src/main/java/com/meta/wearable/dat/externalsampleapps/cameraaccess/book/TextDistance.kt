// TextDistance - character and word error rates
//
// CER = character edit distance / reference length; WER = word edit distance / reference word
// count. Whitespace is collapsed first so line-break differences between the OCR output and the
// hand transcription don't count as errors. Used by the ML Kit folder harness and by page dedup.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.book

object TextDistance {

  fun normalize(text: String): String = text.trim().replace(Regex("\\s+"), " ")

  fun words(text: String): List<String> = normalize(text).split(' ').filter { it.isNotEmpty() }

  fun cer(reference: String, hypothesis: String): Float {
    val ref = normalize(reference)
    val hyp = normalize(hypothesis)
    if (ref.isEmpty()) return if (hyp.isEmpty()) 0f else 1f
    return levenshtein(ref.toList(), hyp.toList()).toFloat() / ref.length
  }

  fun wer(reference: String, hypothesis: String): Float {
    val ref = words(reference)
    val hyp = words(hypothesis)
    if (ref.isEmpty()) return if (hyp.isEmpty()) 0f else 1f
    return levenshtein(ref, hyp).toFloat() / ref.size
  }

  /** Edit distance with two rolling rows, so whole pages (thousands of chars) stay cheap. */
  fun <T> levenshtein(a: List<T>, b: List<T>): Int {
    if (a.isEmpty()) return b.size
    if (b.isEmpty()) return a.size
    var prev = IntArray(b.size + 1) { it }
    var cur = IntArray(b.size + 1)
    for (i in 1..a.size) {
      cur[0] = i
      for (j in 1..b.size) {
        val cost = if (a[i - 1] == b[j - 1]) 0 else 1
        cur[j] = minOf(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
      }
      val t = prev
      prev = cur
      cur = t
    }
    return prev[b.size]
  }
}
