// WordLookup - which word the user means, and what the dictionary says about it
//
// Speech recognition is bad at exactly the words people ask about: "recondite" comes back as
// "recon dight", "reconnect" or "wreck and right". So a word asked about is first looked for in the
// text that was read (with inflections: "expound" finds "expounding"); if it isn't there, the closest
// word in the text that sounds or looks like it is offered instead ("Did you mean recondite?");
// only then is the word looked up as heard. The word in the text decides which part of speech comes
// first ("expounding" -> the verb). Pure Kotlin.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ask

class WordLookup(private val dictionary: Dictionary, private val lemmatiser: Lemmatiser = Lemmatiser(dictionary)) {

  /** What to define. [corrected]: the text's word was offered instead of what was heard. */
  data class Choice(val word: String, val heard: String, val inText: Boolean, val corrected: Boolean)

  /** A definition ready to speak: the first answer and the rest for "more". */
  data class Definition(val word: String, val lemma: String?, val text: String, val more: List<String>)

  /** Distinct words of the text, with hyphenated words also split. */
  fun vocabulary(sentences: List<String>): Set<String> {
    val out = LinkedHashSet<String>()
    for (s in sentences) for (w in Words.of(s)) {
      out += w
      if ('-' in w) out += w.split('-').filter { it.isNotEmpty() }
    }
    return out
  }

  /**
   * The word to define for [heard], given the text read ([sentences]). Null only if [heard] is
   * empty. [allowCorrection] false = take the word as heard ("no, the one I said").
   */
  fun choose(heard: String, sentences: List<String>, allowCorrection: Boolean = true): Choice? {
    val h = Lemmatiser.clean(heard)
    if (h.isEmpty()) return null
    val vocab = vocabulary(sentences)
    inText(h, sentences, vocab)?.let { form ->
      // "define expound" with "expounding" in the text: define what was asked, if it's a word.
      val word = if (form != h && lemmatiser.lemma(h) != null) h else form
      return Choice(word, h, inText = true, corrected = false)
    }
    if (allowCorrection) closest(h, vocab)?.let { return Choice(it, h, inText = true, corrected = true) }
    return Choice(h, h, inText = false, corrected = false)
  }

  /** The form in the text that [h] names: itself, an inflection of it, or the words run together. */
  fun inText(h: String, sentences: List<String>, vocab: Set<String> = vocabulary(sentences)): String? {
    if (' ' in h) {
      val flat = sentences.joinToString(" ") { Words.of(it).joinToString(" ") }
      if (" $h " in " $flat ") return h
      val joined = h.replace(" ", "")
      if (joined in vocab) return joined
      return null
    }
    if (h in vocab) return h
    val mine = lemmatiser.lemmas(h).map { it.lemma }.toSet()
    if (mine.isEmpty()) return null
    for (w in vocab) {
      if (w.length < 3 || w.take(2) != h.take(2)) continue
      if (lemmatiser.lemmas(w).any { it.lemma in mine }) return w
    }
    return null
  }

  /**
   * The word in [vocab] that [h] was most likely misheard from, or null. A word that's in the
   * dictionary as heard needs a closer match (the user may really mean it).
   */
  fun closest(h: String, vocab: Set<String>): String? {
    val heardIsWord = lemmatiser.lemma(h) != null
    var best: String? = null
    var bestScore = 0.0
    for (w in vocab) {
      if (w.length < 4 || w in Words.STOPWORDS || w.any { it.isDigit() }) continue
      val letters = Words.letterSimilarity(h, w)
      val sound = Words.soundSimilarity(h, w)
      val ok = if (heardIsWord) sound >= 0.8 && letters >= 0.5 else sound >= 0.75 || letters >= 0.6
      if (!ok) continue
      // Prefer words the dictionary knows, then the closest, then the longer (rarer) word.
      val known = if (lemmatiser.lemma(w) != null) 1.0 else 0.0
      val score = known + letters + sound + w.length / 1000.0
      if (score > bestScore) {
        bestScore = score
        best = w
      }
    }
    return best
  }

  /** The definition of [word] (as in the text or heard): headword, part of speech, senses. */
  fun define(word: String): Definition {
    var lemmas = lemmatiser.lemmas(word)
    // "expounding" in the text is the verb, though WordNet also has the noun "expounding".
    if (word.endsWith("ing") || word.endsWith("ed")) lemmas = lemmas.sortedBy { if (it.pos == 'v') 0 else 1 }
    for (l in lemmas) {
      val entry = dictionary.entry(l.lemma) ?: continue
      // Most senses first; on a tie adjective, verb, noun, adverb ("ephemeral": the adjective).
      val byCount = entry.parts.sortedWith(compareByDescending<Char> { entry.senseCount(it) }.thenBy { "avnr".indexOf(it) })
      val order = if (l.pos != null && l.pos in entry.parts) listOf(l.pos) + byCount.filter { it != l.pos } else byCount
      val (text, more) = AskWording.definition(word, dictionary.senses(entry, order), from = l.lemma.takeIf { it != word })
      return Definition(word, l.lemma, text, more)
    }
    return Definition(word, null, AskWording.notInDictionary(word), emptyList())
  }
}
