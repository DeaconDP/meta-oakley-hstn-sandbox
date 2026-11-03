// SpeechChunker - sentence and clause chunks for TTS
//
// Speaking a page as one utterance makes pause, "back a sentence" and resume coarse, and long
// utterances start late. Paragraphs are split into sentences (not at "Mr." or "J. R. R."), and
// sentences longer than maxChars are split again at clause punctuation (; : — ,), then at a space.
// Each chunk knows its sentence, so "back a sentence" and the bookmark work on whole sentences.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.book

data class SpeechChunk(
    val text: String,
    val paragraph: Int,
    /** Index of the sentence within the page, across paragraphs. */
    val sentence: Int,
    /** The whole sentence this chunk belongs to (for bookmarks). */
    val sentenceText: String,
)

object SpeechChunker {

  const val DEFAULT_MAX_CHARS = 180
  private const val MIN_CLAUSE_CHARS = 30

  private val ABBREVIATIONS =
      setOf(
          "mr", "mrs", "ms", "dr", "st", "prof", "sr", "jr", "vs", "etc", "e.g", "i.e", "no",
          "mt", "capt", "col", "gen", "lt", "rev", "fig", "p", "pp", "cf", "al", "vol", "ch",
      )
  private val CLOSERS = setOf('"', '\'', '”', '’', ')', ']', '»')

  fun chunk(paragraphs: List<String>, maxChars: Int = DEFAULT_MAX_CHARS): List<SpeechChunk> {
    val out = mutableListOf<SpeechChunk>()
    var sentenceIndex = 0
    paragraphs.forEachIndexed { p, paragraph ->
      for (sentence in sentences(paragraph)) {
        for (piece in clauses(sentence, maxChars)) {
          out += SpeechChunk(piece, p, sentenceIndex, sentence)
        }
        sentenceIndex++
      }
    }
    return out
  }

  fun sentences(paragraph: String): List<String> {
    val text = paragraph.trim().replace(Regex("\\s+"), " ")
    if (text.isEmpty()) return emptyList()
    val out = mutableListOf<String>()
    var start = 0
    var i = 0
    while (i < text.length) {
      val c = text[i]
      if (c == '.' || c == '!' || c == '?' || c == '…') {
        var end = i + 1
        while (end < text.length && (text[end] == '.' || text[end] == '!' || text[end] == '?')) end++
        while (end < text.length && text[end] in CLOSERS) end++
        val atEnd = end >= text.length
        val followedBySpace = !atEnd && text[end] == ' '
        if (atEnd || (followedBySpace && startsSentence(text, end + 1) && !isAbbreviation(text, i))) {
          out += text.substring(start, end).trim()
          start = end
          i = end
          continue
        }
      }
      i++
    }
    if (start < text.length) text.substring(start).trim().takeIf { it.isNotEmpty() }?.let { out += it }
    return out
  }

  private fun startsSentence(text: String, at: Int): Boolean {
    if (at >= text.length) return false
    val c = text[at]
    return c.isUpperCase() || c.isDigit() || c in "\"'“‘([«"
  }

  /** True if the period at [dot] ends an abbreviation or an initial rather than a sentence. */
  private fun isAbbreviation(text: String, dot: Int): Boolean {
    if (text[dot] != '.') return false
    var s = dot
    while (s > 0 && (text[s - 1].isLetter() || text[s - 1] == '.')) s--
    val word = text.substring(s, dot).lowercase()
    if (word.isEmpty()) return false
    if (word in ABBREVIATIONS) return true
    // A single capital initial: "J. R. R. Tolkien".
    return word.length == 1 && text[s].isUpperCase()
  }

  fun clauses(sentence: String, maxChars: Int = DEFAULT_MAX_CHARS): List<String> {
    if (sentence.length <= maxChars) return listOf(sentence)
    // Split after clause punctuation, keeping the punctuation on the left piece.
    val pieces = mutableListOf<String>()
    var last = 0
    for (i in sentence.indices) {
      val c = sentence[i]
      val isBreak =
          (c == ';' || c == ':' || c == ',') && i + 1 < sentence.length && sentence[i + 1] == ' ' ||
              (c == '—' && i > 0)
      if (isBreak) {
        pieces += sentence.substring(last, i + 1)
        last = i + 1
      }
    }
    pieces += sentence.substring(last)
    // Greedily pack pieces up to maxChars, never emitting a fragment shorter than MIN_CLAUSE_CHARS
    // unless it's the tail.
    val packed = mutableListOf<String>()
    val sb = StringBuilder()
    for (piece in pieces) {
      if (sb.length >= MIN_CLAUSE_CHARS && sb.length + piece.length > maxChars) {
        packed += sb.toString().trim()
        sb.setLength(0)
      }
      sb.append(piece)
    }
    if (sb.isNotBlank()) packed += sb.toString().trim()
    return packed.flatMap { hardWrap(it, maxChars) }.filter { it.isNotEmpty() }
  }

  private fun hardWrap(text: String, maxChars: Int): List<String> {
    if (text.length <= maxChars) return listOf(text)
    val out = mutableListOf<String>()
    var rest = text
    while (rest.length > maxChars) {
      val cut = rest.lastIndexOf(' ', maxChars).takeIf { it > 0 } ?: maxChars
      out += rest.substring(0, cut).trim()
      rest = rest.substring(cut).trim()
    }
    if (rest.isNotEmpty()) out += rest
    return out
  }

  /**
   * Chunk index for "back a sentence" from [current]: the first chunk of the previous sentence, or
   * of the current one if it is the first.
   */
  fun previousSentenceStart(chunks: List<SpeechChunk>, current: Int): Int {
    if (chunks.isEmpty()) return 0
    val idx = current.coerceIn(0, chunks.size - 1)
    val target = (chunks[idx].sentence - 1).coerceAtLeast(chunks.first().sentence)
    return chunks.indexOfFirst { it.sentence == target }.coerceAtLeast(0)
  }
}
