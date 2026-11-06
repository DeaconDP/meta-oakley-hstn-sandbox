// Dictionary - the bundled WordNet 3.0 definitions, looked up on the phone with no network
//
// assets/ask/wordnet.wnask is built offline by scripts/build_ask_dictionary.py from Princeton
// WordNet 3.0 (licence in the file's '#' header and in notes/ask-about-the-text.md): 117 659
// definitions, 147 306 lemmas in WordNet's sense order, 5 947 irregular forms. About 3.5 MB gzip'd,
// 10 MB unpacked (gzip data, not named .gz: the Android Gradle plugin would unpack it into the APK).
// It's read once into one ByteArray; lemma lines are sorted by bytes, so a lookup is
// a binary search over line offsets (no per-entry objects, so loading is one pass over the bytes).
// Inflections and spellings are Lemmatiser's job; this class only knows exact lemmas.
// Pure Kotlin, JVM-tested against the real asset.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ask

import java.io.InputStream
import java.util.zip.GZIPInputStream

class Dictionary private constructor(
    private val data: ByteArray,
    private val glossStart: IntArray,
    private val lemmaStart: IntArray,
    private val exceptions: Map<String, List<Pair<Char, String>>>,
) {

  /** One meaning. [pos] is n (noun), v (verb), a (adjective) or r (adverb). */
  data class Sense(val pos: Char, val gloss: String)

  /** A lemma and its senses, grouped by part of speech in WordNet's order (most common first). */
  data class Entry(val lemma: String, val groups: List<Pair<Char, List<Int>>>) {
    val parts: List<Char>
      get() = groups.map { it.first }

    fun senseCount(pos: Char): Int = groups.firstOrNull { it.first == pos }?.second?.size ?: 0

    val totalSenses: Int
      get() = groups.sumOf { it.second.size }
  }

  val lemmaCount: Int
    get() = lemmaStart.size

  val definitionCount: Int
    get() = glossStart.size

  /** The definition for synset [id]. */
  fun gloss(id: Int): String {
    val start = glossStart[id]
    return String(data, start, lineEnd(start) - start, Charsets.UTF_8)
  }

  /** The entry for [lemma] exactly (lower case, spaces between words), or null. */
  fun entry(lemma: String): Entry? {
    val key = lemma.lowercase().toByteArray(Charsets.UTF_8)
    val line = find(key) ?: return null
    val tab = line + key.size
    val end = lineEnd(tab)
    val groups =
        String(data, tab + 1, end - tab - 1, Charsets.UTF_8).split(';').mapNotNull { g ->
          if (g.length < 2) null else g[0] to g.substring(1).split(',').map { it.toInt(36) }
        }
    return Entry(lemma.lowercase(), groups)
  }

  fun contains(lemma: String): Boolean = find(lemma.lowercase().toByteArray(Charsets.UTF_8)) != null

  /** All senses of [entry], parts of speech in [posOrder] (default: WordNet's), senses in order. */
  fun senses(entry: Entry, posOrder: List<Char> = entry.parts): List<Sense> =
      posOrder.flatMap { pos ->
        entry.groups.firstOrNull { it.first == pos }?.second.orEmpty().map { Sense(pos, gloss(it)) }
      }

  /** Irregular forms: "mice" -> [(n, mouse)], "went" -> [(v, go)]. */
  fun irregular(form: String): List<Pair<Char, String>> = exceptions[form.lowercase()].orEmpty()

  // MARK: - Lookup internals

  private fun lineEnd(from: Int): Int {
    var i = from
    while (i < data.size && data[i] != NL) i++
    return i
  }

  /** Line start of the lemma line whose key is exactly [key], by binary search. */
  private fun find(key: ByteArray): Int? {
    var lo = 0
    var hi = lemmaStart.size - 1
    while (lo <= hi) {
      val mid = (lo + hi) ushr 1
      val c = compareKey(lemmaStart[mid], key)
      when {
        c < 0 -> lo = mid + 1
        c > 0 -> hi = mid - 1
        else -> return lemmaStart[mid]
      }
    }
    return null
  }

  /** Compares the lemma at [line] (up to its tab) with [key], as unsigned bytes. */
  private fun compareKey(line: Int, key: ByteArray): Int {
    var i = 0
    while (true) {
      val b = data[line + i]
      val lineDone = b == TAB
      val keyDone = i == key.size
      if (lineDone && keyDone) return 0
      if (lineDone) return -1
      if (keyDone) return 1
      val d = (b.toInt() and 0xff) - (key[i].toInt() and 0xff)
      if (d != 0) return d
      i++
    }
  }

  companion object {
    private const val NL = '\n'.code.toByte()
    private const val TAB = '\t'.code.toByte()

    /** Reads the gzip'd asset. */
    fun load(gz: InputStream): Dictionary = parse(GZIPInputStream(gz, 64 * 1024).use { it.readBytes() })

    /** Parses the unpacked file (format in scripts/build_ask_dictionary.py). */
    fun parse(data: ByteArray): Dictionary {
      var pos = 0
      var glosses = IntArray(0)
      var lemmas = IntArray(0)
      val exc = HashMap<String, MutableList<Pair<Char, String>>>()

      fun nextLine(): Int {
        val start = pos
        while (pos < data.size && data[pos] != NL) pos++
        pos++ // past '\n'
        return start
      }

      fun text(start: Int): String {
        var e = start
        while (e < data.size && data[e] != NL) e++
        return String(data, start, e - start, Charsets.UTF_8)
      }

      require(text(0).startsWith("#WNASK 1")) { "not a WNASK 1 dictionary" }
      while (pos < data.size) {
        val start = nextLine()
        if (data[start] == '#'.code.toByte()) continue
        val header = text(start)
        val count = header.substringAfter(' ').toInt()
        when {
          header.startsWith("@S") -> glosses = IntArray(count) { nextLine() }
          header.startsWith("@L") -> lemmas = IntArray(count) { nextLine() }
          header.startsWith("@X") ->
              repeat(count) {
                val parts = text(nextLine()).split('\t')
                if (parts.size == 3) {
                  val list = exc.getOrPut(parts[0]) { mutableListOf() }
                  for (base in parts[2].split(',')) list += parts[1][0] to base
                }
              }
          else -> error("bad section: $header")
        }
      }
      return Dictionary(data, glosses, lemmas, exc)
    }
  }
}
