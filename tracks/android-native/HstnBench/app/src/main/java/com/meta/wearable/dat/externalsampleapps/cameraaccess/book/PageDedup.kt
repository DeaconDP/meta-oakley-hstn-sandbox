// PageDedup - "is this the page I just read?"
//
// The page-turn detector fires on any big motion followed by stillness, and a head bump looks the
// same as a page turn. Before reading a new capture, compare its text with the last page read. Two
// OCR passes over the same page differ in a few characters and in how much of the page is in frame,
// so this compares word bigrams by containment (shared / smaller set) rather than exact equality: a
// re-framed half of the same page still counts as the same page, while consecutive book pages share
// almost no bigrams.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.book

object PageDedup {

  /** Containment at or above this means "same page". */
  const val SAME_PAGE_THRESHOLD = 0.5f

  /** Below this many words a page is too short to judge; fall back to character similarity. */
  private const val MIN_WORDS = 6

  fun normalizeWords(text: String): List<String> =
      text
          .lowercase()
          .replace(Regex("[\\u00AD\\u2010\\u2011]"), "")
          .split(Regex("[^\\p{L}\\p{N}]+"))
          .filter { it.isNotEmpty() }

  /** 0..1: how much of the shorter text's bigrams also appear in the other. */
  fun similarity(a: String, b: String): Float {
    val wa = normalizeWords(a)
    val wb = normalizeWords(b)
    if (wa.isEmpty() || wb.isEmpty()) return 0f
    if (wa.size < MIN_WORDS || wb.size < MIN_WORDS) {
      return 1f - TextDistance.cer(wa.joinToString(" "), wb.joinToString(" ")).coerceAtMost(1f)
    }
    val ba = bigrams(wa)
    val bb = bigrams(wb)
    val shared = ba.count { it in bb }
    return shared.toFloat() / minOf(ba.size, bb.size)
  }

  fun isSamePage(previous: String?, current: String, threshold: Float = SAME_PAGE_THRESHOLD) =
      previous != null && similarity(previous, current) >= threshold

  private fun bigrams(words: List<String>): Set<String> =
      if (words.size == 1) setOf(words[0]) else words.zipWithNext { x, y -> "$x $y" }.toSet()
}
