// Bookmark - where to pick up after a fold or a session end
//
// Folding the glasses ends the DAT session, so the reader saves a bookmark on every sentence: how
// many pages have been read and the last sentence spoken. On resume, the first capture is OCR'd,
// the sentence is found again (fuzzily, since OCR varies), and reading starts after it.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.book

data class Bookmark(val pagesRead: Int, val lastSentence: String) {

  /** Single-line-safe encoding for SharedPreferences. */
  fun encode(): String = "$pagesRead\t${lastSentence.replace('\t', ' ').replace('\n', ' ')}"

  /**
   * Index of the chunk to resume from in [chunks]: the first chunk after [lastSentence], or null if
   * that sentence isn't on this page (a different page is in view, so start from the top).
   */
  fun resumeIndex(chunks: List<SpeechChunk>, minSimilarity: Float = 0.8f): Int? {
    if (lastSentence.isBlank()) return null
    var bestSentence = -1
    var bestScore = 0f
    for (chunk in chunks.distinctBy { it.sentence }) {
      val score = 1f - TextDistance.cer(lastSentence, chunk.sentenceText).coerceAtMost(1f)
      if (score > bestScore) {
        bestScore = score
        bestSentence = chunk.sentence
      }
    }
    if (bestScore < minSimilarity) return null
    val next = chunks.indexOfFirst { it.sentence > bestSentence }
    return if (next == -1) chunks.size else next
  }

  companion object {
    fun decode(encoded: String?): Bookmark? {
      if (encoded.isNullOrEmpty()) return null
      val tab = encoded.indexOf('\t')
      if (tab <= 0) return null
      val pages = encoded.substring(0, tab).toIntOrNull() ?: return null
      return Bookmark(pages, encoded.substring(tab + 1))
    }
  }
}
