// TextTools - finding things in the text that was read: sentences, mentions, matches, a recap
//
// Everything "Ask about the text" does without a dictionary works on the sentences already read
// out: the book's pages up to the sentence being read (not the rest of the page, which the user
// hasn't heard yet), or a letter. Here:
//
//   Sentences   split text into sentences (not after "Mr." or "St."; paragraphs always break).
//   ReadText    the sentences read so far from a RecentText snapshot, and a short tail of them to
//               keep with the bookmark for "what happened last time" after the app closes.
//   Words       word lists, a sound-alike key and similarity scores, for loose matching: speech
//               recognition hears "Mr. Bennett" for "Mr. Bennet" and "recon dight" for "recondite".
//   Mentions    "who is Watson": the sentences that mention a name (first one, latest ones).
//   Search      "what did it say about the fire": sentences with the words asked about.
//   Recap       the last few sentences, about 60 words.
//
// Pure Kotlin, JVM-tested on the book fixtures.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ask

import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.RecentText
import kotlin.math.max
import kotlin.math.min

object Sentences {

  private val ABBREVIATIONS =
      setOf("mr", "mrs", "ms", "dr", "st", "sr", "jr", "prof", "rev", "capt", "col", "gen", "lt", "sgt",
          "mt", "no", "vol", "ch", "fig", "e.g", "i.e", "etc", "vs", "messrs", "mme", "mlle", "esq")

  /** Sentences in [text], trimmed, whitespace collapsed. A blank line always ends a sentence. */
  fun split(text: String): List<String> {
    val out = mutableListOf<String>()
    for (para in text.split(Regex("\\n\\s*\\n"))) {
      val p = para.replace(Regex("\\s+"), " ").trim()
      if (p.isEmpty()) continue
      var start = 0
      var i = 0
      while (i < p.length) {
        val c = p[i]
        if (c == '.' || c == '!' || c == '?') {
          var end = i + 1
          while (end < p.length && p[end] in "\"'”’)]") end++
          val atEnd = end >= p.length
          val nextIsStart = !atEnd && p[end] == ' ' && end + 1 < p.length &&
              (p[end + 1].isUpperCase() || p[end + 1] in "\"'“‘(" || p[end + 1].isDigit())
          if (atEnd || nextIsStart) {
            val word = p.substring(start, i).substringAfterLast(' ').lowercase().trim('"', '\'', '“', '(')
            val isAbbrev = c == '.' && (word in ABBREVIATIONS || (word.length == 1 && word[0].isLetter()))
            if (!isAbbrev || atEnd) {
              out += p.substring(start, end).trim()
              start = end
            }
          }
          i = end
          continue
        }
        i++
      }
      if (start < p.length) p.substring(start).trim().takeIf { it.isNotEmpty() }?.let { out += it }
    }
    return out
  }
}

object ReadText {

  /**
   * The sentences [snapshot]'s tool has read out, oldest first: every passage, the last one only up
   * to and including the sentence being read now ([RecentText.Snapshot.current]), if it's found.
   */
  fun sentences(snapshot: RecentText.Snapshot?): List<String> {
    if (snapshot == null) return emptyList()
    val passages = snapshot.passages
    if (passages.isEmpty()) return snapshot.current?.let(Sentences::split).orEmpty()
    val earlier = passages.dropLast(1).flatMap(Sentences::split)
    val last = Sentences.split(passages.last())
    val current = snapshot.current ?: return earlier + last
    val at = locate(last, current) ?: return earlier + last
    return earlier + last.take(at + 1)
  }

  /** Index of the sentence in [sentences] that best matches [sentence] (loosely), or null. */
  fun locate(sentences: List<String>, sentence: String): Int? {
    val want = Words.of(sentence)
    if (want.isEmpty()) return null
    var best = -1
    var bestScore = 0.0
    for ((i, s) in sentences.withIndex()) {
      val have = Words.of(s)
      // The chunk being read can be part of a long sentence, or several short ones.
      val shared = want.toSet().intersect(have.toSet()).size.toDouble()
      val score = shared / min(want.toSet().size, max(1, have.toSet().size))
      if (score > bestScore + 1e-9) {
        bestScore = score
        best = i
      }
    }
    return if (bestScore >= 0.6) best else null
  }

  /** The last read sentences, at most [maxChars], whole sentences, to keep next to the bookmark. */
  fun tail(snapshot: RecentText.Snapshot?, maxChars: Int = 3_000): String? {
    val all = sentences(snapshot)
    if (all.isEmpty()) return null
    val kept = ArrayDeque<String>()
    var size = 0
    for (s in all.asReversed()) {
      if (kept.isNotEmpty() && size + s.length + 1 > maxChars) break
      kept.addFirst(s)
      size += s.length + 1
    }
    return kept.joinToString(" ")
  }
}

object Words {

  private val WORD = Regex("[A-Za-z0-9]+(?:['’-][A-Za-z0-9]+)*")

  val STOPWORDS =
      setOf("a", "an", "the", "and", "or", "but", "of", "to", "in", "on", "at", "by", "for", "with",
          "from", "as", "is", "was", "are", "were", "be", "been", "it", "its", "this", "that", "these",
          "those", "he", "she", "they", "him", "her", "them", "his", "their", "i", "me", "my", "we",
          "us", "our", "you", "your", "what", "which", "who", "whom", "about", "had", "has", "have",
          "do", "did", "does", "not", "no", "so", "if", "then", "there", "here", "said", "say", "says",
          "anything", "something", "bit", "part", "thing", "any", "all", "some", "very", "upon", "into",
          "would", "could", "should", "will", "shall", "one", "two", "up", "out", "over")

  /** Titles dropped from a name asked about ("Mr. Bennet" -> bennet). */
  val TITLES =
      setOf("mr", "mister", "mrs", "missus", "ms", "miss", "dr", "doctor", "sir", "lady", "lord",
          "madam", "madame", "professor", "prof", "captain", "colonel", "inspector", "the", "a", "an",
          "old", "young", "master", "uncle", "aunt", "st", "saint")

  /** Lower-case words of [text], possessive 's dropped, apostrophes straightened. */
  fun of(text: String): List<String> =
      WORD.findAll(text).map { norm(it.value) }.filter { it.isNotEmpty() }.toList()

  /** One word, lower case, possessive dropped. */
  fun norm(word: String): String =
      word.lowercase().replace('’', '\'').removeSuffix("'s").removeSuffix("'").trim('\'', '-')

  /** The words of [text] as they're written (for saying a name the way the book has it). */
  fun asWritten(text: String): List<String> = WORD.findAll(text).map { it.value.removeSuffix("'s").removeSuffix("’s") }.toList()

  /** A rough sound-alike key: consonant skeleton with common spellings merged. */
  fun soundKey(word: String): String {
    var w = word.lowercase().filter { it in 'a'..'z' }
    if (w.isEmpty()) return ""
    w = w.replace(Regex("^kn|^gn|^pn"), "n").replace(Regex("^wr"), "r").replace(Regex("^ps"), "s")
        .replace(Regex("^x"), "s").replace("ght", "t").replace("tch", "ch").replace("sch", "sk")
        .replace("ph", "f").replace("ck", "k").replace("qu", "kw").replace("dg", "j")
        .replace(Regex("c(?=[eiy])"), "s").replace("c", "k").replace("q", "k").replace("x", "ks")
        .replace("z", "s").replace(Regex("mb$"), "m").replace("wh", "w").replace("gh", "")
        .replace(Regex("(?<=[^aeiou])h"), "").replace(Regex("(?<=[aeiou])[wy]"), "")
    val first = w[0]
    val rest = w.substring(1).filter { it !in "aeiouy" }
    val key = StringBuilder().append(if (first in "aeiouy") 'a' else first)
    for (c in rest) if (key.last() != c) key.append(c)
    return key.toString()
  }

  fun levenshtein(a: String, b: String): Int {
    if (a == b) return 0
    if (a.isEmpty()) return b.length
    if (b.isEmpty()) return a.length
    var prev = IntArray(b.length + 1) { it }
    var cur = IntArray(b.length + 1)
    for (i in 1..a.length) {
      cur[0] = i
      for (j in 1..b.length) {
        val cost = if (a[i - 1] == b[j - 1]) 0 else 1
        cur[j] = min(min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost)
      }
      val t = prev
      prev = cur
      cur = t
    }
    return prev[b.length]
  }

  /** 1 = same letters, 0 = nothing alike (spaces ignored). */
  fun letterSimilarity(a: String, b: String): Double {
    val x = a.lowercase().filter { it.isLetterOrDigit() }
    val y = b.lowercase().filter { it.isLetterOrDigit() }
    if (x.isEmpty() || y.isEmpty()) return 0.0
    return 1.0 - levenshtein(x, y).toDouble() / max(x.length, y.length)
  }

  /** 1 = sounds the same (by [soundKey]), 0 = nothing alike. */
  fun soundSimilarity(a: String, b: String): Double {
    val x = soundKey(a.replace(" ", ""))
    val y = soundKey(b.replace(" ", ""))
    if (x.length < 2 || y.length < 2) return if (x == y && x.isNotEmpty()) 0.5 else 0.0
    return 1.0 - levenshtein(x, y).toDouble() / max(x.length, y.length)
  }

  /** Two words that are probably the same name, heard or OCR'd a little differently. */
  fun sameName(heard: String, written: String): Boolean {
    if (heard == written) return true
    // Plurals and possessives: "holmes" / "holme", "watsons".
    if (heard.removeSuffix("s") == written.removeSuffix("s")) return true
    if (heard.length < 4 || written.length < 4) return false
    val d = levenshtein(heard, written)
    val allowed = if (max(heard.length, written.length) >= 7) 2 else 1
    if (d <= allowed && heard[0] == written[0]) return true
    return heard[0] == written[0] && soundKey(heard) == soundKey(written) && d <= 3
  }
}

/** A sentence and where it is in the list of sentences read (0 = the first). */
data class Found(val index: Int, val sentence: String)

object Mentions {

  /** The words of a name asked about that have to appear: titles and "the" dropped. */
  fun keyWords(subject: String): List<String> {
    val words = Words.of(subject)
    val kept = words.filter { it !in Words.TITLES }
    return kept.ifEmpty { words.filter { it !in setOf("the", "a", "an") } }
  }

  /**
   * Sentences in [sentences] that mention [subject], in reading order. All of its key words must be
   * in the sentence (loosely); if no sentence has them all, a sentence with the last one (the
   * surname: "Sherlock Holmes" -> Holmes) counts, if that word is written as a name in the text.
   */
  fun find(sentences: List<String>, subject: String): List<Found> {
    val keys = keyWords(subject)
    if (keys.isEmpty()) return emptyList()
    val words = sentences.map(Words::of)
    fun has(i: Int, key: String) = words[i].any { Words.sameName(key, it) }
    val all = sentences.indices.filter { i -> keys.all { has(i, it) } }
    if (keys.size == 1) return all.map { Found(it, sentences[it]) }
    // A surname alone counts too ("Sherlock Holmes" -> "Holmes was sitting"), if the text writes it as a name.
    val last = keys.last()
    val capitalised = sentences.any { s -> Words.asWritten(s).any { it[0].isUpperCase() && Words.sameName(last, Words.norm(it)) } }
    val surname = if (capitalised) sentences.indices.filter { has(it, last) } else emptyList()
    return (all + surname).distinct().sorted().map { Found(it, sentences[it]) }
  }

  /** How the text writes the name asked about ("holmes" -> "Holmes", "mr bennet" -> "Mr. Bennet"). */
  fun displayName(sentences: List<String>, found: List<Found>, subject: String): String {
    val keys = keyWords(subject)
    for (f in found) {
      val written = Words.asWritten(f.sentence)
      val idx = written.indexOfFirst { w -> keys.any { Words.sameName(it, Words.norm(w)) } }
      if (idx < 0) continue
      // Take the whole run of the name: title and capitalised words around it.
      var a = idx
      var b = idx
      // Back over titles, and capitalised words that aren't just starting the sentence ("Well, Watson").
      while (a > 0 && written[a - 1][0].isUpperCase() && Words.norm(written[a - 1]) !in Words.STOPWORDS &&
          (a - 1 > 0 || Words.norm(written[a - 1]) in Words.TITLES)) a--
      while (b < written.lastIndex && written[b + 1][0].isUpperCase() && keys.any { Words.sameName(it, Words.norm(written[b + 1])) }) b++
      val run = written.subList(a, b + 1).joinToString(" ") { w ->
        if (Words.norm(w) in setOf("mr", "mrs", "ms", "dr", "st")) "$w." else w
      }
      return if (run.isNotEmpty() && run[0].isUpperCase()) run else subject
    }
    return subject.split(' ').joinToString(" ") { w -> w.replaceFirstChar { it.uppercase() } }
  }
}

object Search {

  /** The words of a search worth matching ("the fire" -> fire). */
  fun keyWords(subject: String): List<String> = Words.of(subject).filter { it !in Words.STOPWORDS }.distinct()

  private fun stem(w: String): String =
      w.removeSuffix("'s").let {
        when {
          it.length > 5 && it.endsWith("ing") -> it.dropLast(3)
          it.length > 4 && it.endsWith("ed") -> it.dropLast(2)
          it.length > 4 && it.endsWith("es") -> it.dropLast(2)
          it.length > 3 && it.endsWith("s") -> it.dropLast(1)
          else -> it
        }
      }

  private fun matches(key: String, word: String): Boolean {
    if (key == word) return true
    val k = stem(key)
    val w = stem(word)
    if (k == w || (k.length >= 4 && (w.startsWith(k) || k.startsWith(w)) && min(k.length, w.length) >= 4)) return true
    // Loose (misheard) matching only for longer words: "fire" must not find "fine".
    return key.length >= 6 && Words.sameName(key, word)
  }

  /**
   * Sentences that have the words of [subject], best first: most key words matched, then reading
   * order. A one- or two-word search needs every word; a longer one needs two thirds of them.
   */
  fun find(sentences: List<String>, subject: String): List<Found> {
    val keys = keyWords(subject).ifEmpty { Words.of(subject) }
    if (keys.isEmpty()) return emptyList()
    val need = if (keys.size <= 2) keys.size else (keys.size * 2 + 2) / 3
    val phrase = keys.joinToString(" ")
    return sentences.mapIndexedNotNull { i, s ->
          val words = Words.of(s).flatMap { if ('-' in it) listOf(it) + it.split('-') else listOf(it) }
          val hit = keys.count { k -> words.any { matches(k, it) } }
          if (hit < need) null else Triple(i, hit + if (Words.of(s).joinToString(" ").contains(phrase)) 1 else 0, s)
        }
        .sortedWith(compareByDescending<Triple<Int, Int, String>> { it.second }.thenBy { it.first })
        .map { Found(it.first, it.third) }
  }
}

object Recap {

  /** The last sentences of [sentences], at least one, about [words] words in all. */
  fun last(sentences: List<String>, words: Int = 60): List<String> {
    val out = ArrayDeque<String>()
    var count = 0
    for (s in sentences.asReversed()) {
      val n = Words.of(s).size
      if (out.isNotEmpty() && count + n > words) break
      out.addFirst(s)
      count += n
    }
    return out.toList()
  }
}
