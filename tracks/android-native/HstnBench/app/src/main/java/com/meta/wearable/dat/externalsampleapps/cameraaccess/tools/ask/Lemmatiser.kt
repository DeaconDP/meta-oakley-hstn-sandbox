// Lemmatiser - from a word as read or heard to the dictionary's headword
//
// "expounding" -> expound, "travellers" -> traveller, "mice" -> mouse, "colour" / "color", "realised"
// -> realize. WordNet's own approach (morphy): its irregular-forms lists first, then suffix rules per
// part of speech (nouns: -s, -es, -ies, -men; verbs: -s, -es, -ed, -ing; adjectives: -er, -est),
// keeping only bases the dictionary has as that part of speech. Added on top: undoubling ("stopped"
// -> stop, "travelled" -> travel), "-ly" adverbs to adjectives, hyphens, possessives, and British /
// American spellings (-our/-or, -ise/-ize, -isation, -yse/-yze, -tre/-ter, -ll-/-l-, ae/oe, -ogue,
// -ence/-ense, grey/gray, programme), so either spelling finds the entry WordNet happens to use.
// Pure Kotlin; the dictionary is passed in as two functions so the rules can be tested alone.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ask

class Lemmatiser(
    /** The parts of speech [lemma] has in the dictionary (empty if it isn't there). */
    private val partsOf: (String) -> List<Char>,
    /** Irregular forms: (pos, base). */
    private val irregular: (String) -> List<Pair<Char, String>> = { emptyList() },
) {

  constructor(dictionary: Dictionary) : this({ dictionary.entry(it)?.parts.orEmpty() }, dictionary::irregular)

  /** A headword for a word, and the part of speech the inflection points to (null: as written). */
  data class Lemma(val lemma: String, val pos: Char?)

  private class SuffixRule(val pos: Char, val suffix: String, val ending: String)

  private val rules =
      listOf(
          SuffixRule('n', "ses", "s"), SuffixRule('n', "xes", "x"), SuffixRule('n', "zes", "z"),
          SuffixRule('n', "ches", "ch"), SuffixRule('n', "shes", "sh"), SuffixRule('n', "men", "man"),
          SuffixRule('n', "ies", "y"), SuffixRule('n', "s", ""),
          SuffixRule('v', "ies", "y"), SuffixRule('v', "es", "e"), SuffixRule('v', "es", ""),
          SuffixRule('v', "ed", "e"), SuffixRule('v', "ed", ""), SuffixRule('v', "ing", "e"),
          SuffixRule('v', "ing", ""), SuffixRule('v', "s", ""), SuffixRule('v', "ied", "y"),
          SuffixRule('a', "est", ""), SuffixRule('a', "er", ""), SuffixRule('a', "est", "e"),
          SuffixRule('a', "er", "e"), SuffixRule('a', "iest", "y"), SuffixRule('a', "ier", "y"),
          SuffixRule('r', "ly", ""), SuffixRule('r', "ily", "y"), SuffixRule('r', "ally", ""),
      )

  /** Every headword [word] could be, best first: as written, irregular, then by rule. */
  fun lemmas(word: String): List<Lemma> {
    val w = clean(word)
    if (w.isEmpty()) return emptyList()
    val out = LinkedHashMap<String, Lemma>()
    fun add(lemma: String, pos: Char?) {
      if (lemma.isNotEmpty() && lemma !in out) out[lemma] = Lemma(lemma, pos)
    }
    val forms = listOf(w) + hyphenForms(w) + spellings(w)
    for (f in forms) if (partsOf(f).isNotEmpty()) add(f, null)
    for (f in forms) for ((pos, base) in irregular(f)) if (partsOf(base).isNotEmpty()) add(base, pos)
    for (f in forms) {
      for (rule in rules) {
        if (!f.endsWith(rule.suffix) || f.length - rule.suffix.length < 2) continue
        val stem = f.dropLast(rule.suffix.length)
        val bases = mutableListOf(stem + rule.ending)
        // stopped -> stopp -> stop; travelled -> travell -> travel
        if (rule.ending.isEmpty() && rule.pos != 'n' && stem.length >= 3 &&
            stem.last() == stem[stem.length - 2] && stem.last() !in VOWELS) {
          bases += stem.dropLast(1)
        }
        for (b in bases) {
          // An adverb's base is an adjective; everything else must have the rule's part of speech.
          val want = if (rule.pos == 'r') 'a' else rule.pos
          for (candidate in listOf(b) + spellings(b)) {
            if (want in partsOf(candidate)) add(candidate, want)
          }
        }
      }
    }
    return out.values.toList()
  }

  /** The best headword, or null if the dictionary has nothing for [word]. */
  fun lemma(word: String): Lemma? = lemmas(word).firstOrNull()

  companion object {
    private const val VOWELS = "aeiou"

    /** Lower case, possessive and outer punctuation off, spaces collapsed. */
    fun clean(word: String): String =
        word.lowercase()
            .replace('’', '\'')
            .replace(Regex("[^a-z0-9' .-]"), " ")
            .replace(Regex("\\s+"), " ")
            .trim(' ', '\'', '.', '-')
            .replace(Regex("'s$|s'$")) { if (it.value == "s'") "s" else "" }

    private fun hyphenForms(w: String): List<String> =
        if ('-' in w) listOf(w.replace('-', ' '), w.replace("-", "")) else emptyList()

    private class Swap(val from: Regex, val to: String)

    // Each applied both ways where it makes sense; overgeneration is harmless (only real words match).
    private val SWAPS =
        listOf(
            Swap(Regex("our(?=s?$|ed$|ing$|ite|able|er|ful|less)"), "or"),
            Swap(Regex("(?<=[^aeiou])or(?=s?$|ed$|ing$|ite|able|ful|less)"), "our"),
            Swap(Regex("is(?=e$|es$|ed$|ing$|ation|er$|ers$)"), "iz"),
            Swap(Regex("iz(?=e$|es$|ed$|ing$|ation|er$|ers$)"), "is"),
            Swap(Regex("ys(?=e$|es$|ed$|ing$)"), "yz"),
            Swap(Regex("yz(?=e$|es$|ed$|ing$)"), "ys"),
            Swap(Regex("tre(?=s?$)"), "ter"),
            Swap(Regex("(?<=[^aeiou])ter(?=s?$)"), "tre"),
            Swap(Regex("(?<=[aeiou])ll(?=ed$|ing$|er$|ers$|or$|ors$|ery$)"), "l"),
            Swap(Regex("(?<=[aeiou])l(?=ed$|ing$|er$|ers$|or$|ors$|ery$)"), "ll"),
            Swap(Regex("ae"), "e"),
            Swap(Regex("oe(?=[a-z])"), "e"),
            Swap(Regex("ogue(?=s?$)"), "og"),
            Swap(Regex("(?<=[aeiou][a-z])og(?=s?$)"), "ogue"),
            Swap(Regex("ence(?=s?$)"), "ense"),
            Swap(Regex("ense(?=s?$)"), "ence"),
            Swap(Regex("grey"), "gray"),
            Swap(Regex("gray"), "grey"),
            Swap(Regex("amme(?=s?$)"), "am"),
            Swap(Regex("eable$"), "able"),
        )

    /** Other spellings of [w] (British <-> American), up to two changes deep. Not [w] itself. */
    fun spellings(w: String): List<String> {
      val out = LinkedHashSet<String>()
      var frontier = listOf(w)
      repeat(2) {
        val next = mutableListOf<String>()
        for (f in frontier) {
          for (s in SWAPS) {
            if (!s.from.containsMatchIn(f)) continue
            val v = s.from.replace(f, s.to)
            if (v != w && out.add(v)) next += v
          }
        }
        frontier = next
      }
      return out.take(24)
    }
  }
}
