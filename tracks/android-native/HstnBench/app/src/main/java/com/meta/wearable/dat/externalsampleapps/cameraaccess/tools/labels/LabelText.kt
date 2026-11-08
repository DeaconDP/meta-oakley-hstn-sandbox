// LabelText - finding things in the text of a label
//
// The label reader reads a label word for word, and also jumps straight to a part of it:
// ingredients, cooking instructions, allergy advice. Labels are short blocks under headings
// ("Ingredients:", "Cooking instructions", "Allergy advice"), so a section is the text after its
// heading up to the next heading of another kind. [nameGuess] takes the biggest print as the
// product's name. [allergenAnswer] answers "does it contain nuts?" from the label and the Open Food
// Facts data: it says yes when it finds the allergen, "may contain" when only traces are mentioned,
// what the label says when it says "free from", and otherwise that it couldn't find it, which is
// never the same as "no" (ROADMAP: abstain rather than guess). Pure Kotlin, JVM-tested.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.labels

/** One OCR line in reading order. [height] is its box height in pixels (bigger print, bigger). */
data class LabelLine(val text: String, val height: Float = 0f, val confidence: Float? = null)

enum class LabelSection { INGREDIENTS, COOKING, ALLERGENS }

object LabelText {

  private val HEADINGS: Map<LabelSection?, Regex> =
      mapOf(
          LabelSection.INGREDIENTS to Regex("\\bINGREDIENTS?\\b\\s*[:;.\\-]?", RegexOption.IGNORE_CASE),
          LabelSection.COOKING to
              Regex(
                  "\\b(COOKING (INSTRUCTIONS|GUIDELINES|GUIDE|METHOD)|PREPARATION( GUIDELINES| INSTRUCTIONS)?|" +
                      "HOW TO (COOK|PREPARE)|TO PREPARE|OVEN( COOK)?|MICROWAVE|HOB|DIRECTIONS)\\b\\s*[:;.\\-]?",
                  RegexOption.IGNORE_CASE,
              ),
          LabelSection.ALLERGENS to
              Regex(
                  "\\b(ALLERGY (ADVICE|INFORMATION|INFO)|ALLERGENS?)\\b\\s*[:;.\\-]?",
                  RegexOption.IGNORE_CASE,
              ),
          // Headings that end a section but aren't sections we jump to.
          null to
              Regex(
                  "\\b(NUTRITION(AL)?( INFORMATION| FACTS)?|TYPICAL VALUES|STORAGE|STORE IN|KEEP REFRIGERATED|" +
                      "ONCE OPENED|BEST BEFORE|USE BY|DISPLAY UNTIL|PACKED IN|PRODUCED (IN|BY)|MANUFACTURED|" +
                      "RECYCL\\w*|NET (WEIGHT|WT))\\b",
                  RegexOption.IGNORE_CASE,
              ),
      )

  /** At most this many lines are taken for one section. */
  private const val MAX_SECTION_LINES = 14

  /**
   * The text of [section] in [lines], without its heading, or null if there's no heading. The
   * cooking section keeps sub-headings (oven, microwave), since they're part of the instructions.
   */
  fun section(lines: List<LabelLine>, section: LabelSection): String? {
    val heading = HEADINGS.getValue(section)
    // A real heading first ("Ingredients:"); a mention ("see ingredients in bold") only if none.
    val start =
        lines.indexOfFirst { isHeading(it.text, heading) }.takeIf { it >= 0 }
            ?: lines.indexOfFirst { heading.containsMatchIn(it.text) }
    if (start < 0) return null
    val first = lines[start].text
    val m = heading.find(first)!!
    val keepHeading = section == LabelSection.COOKING && m.range.first > 0
    val rest = if (section == LabelSection.COOKING) first.trim() else first.substring(m.range.last + 1).trim()
    val out = mutableListOf<String>()
    if (rest.isNotEmpty() || keepHeading) out += rest
    for (i in start + 1 until lines.size) {
      if (out.size >= MAX_SECTION_LINES) break
      val t = lines[i].text
      if (startsOtherSection(t, section)) break
      out += t.trim()
    }
    return out.filter { it.isNotBlank() }.joinToString(" ").trim().ifEmpty { null }
  }

  private fun startsOtherSection(text: String, current: LabelSection): Boolean =
      HEADINGS.any { (s, r) ->
        if (s == current) return@any false
        // Stop markers (nutrition, storage, dates) end a section wherever a line starts with them.
        if (s == null) (r.find(text.trim())?.range?.first ?: 99) <= 2 else isHeading(text, r)
      }

  /**
   * [text] starts with a heading: the words at the start of the line, followed by a colon or
   * nothing else, or in capitals ("INGREDIENTS Oats..."). "ingredients in bold" isn't one.
   */
  private fun isHeading(text: String, r: Regex): Boolean {
    val t = text.trim()
    val m = r.find(t) ?: return false
    if (m.range.first > 2) return false
    val word = m.value.trimEnd()
    val after = t.substring(m.range.last + 1).trim()
    return word.endsWith(':') || word.endsWith('-') || after.isEmpty() || after.startsWith(":") ||
        (word.trimEnd(':', ';', '.', '-', ' ').let { w -> w.any { it.isLetter() } && w == w.uppercase() })
  }

  /** The biggest print on the label, as its likely name: up to two lines near the largest size. */
  fun nameGuess(lines: List<LabelLine>): String? {
    val candidates = lines.filter { l -> l.text.count { it.isLetter() } >= 3 }
    if (candidates.isEmpty()) return null
    val max = candidates.maxOf { it.height }
    if (max <= 0f) return candidates.first().text.trim()
    return candidates.filter { it.height >= max * 0.8f }.take(2).joinToString(" ") { it.text.trim() }
  }

  // MARK: - Allergens

  /** [notTerms] contain a term but aren't the allergen ("cocoa butter" isn't milk). */
  private data class Allergen(
      val name: String,
      val terms: List<String>,
      val tags: List<String>,
      val notTerms: List<String> = emptyList(),
  )

  private val ALLERGENS =
      listOf(
          Allergen("peanuts", listOf("peanut", "groundnut", "arachis"), listOf("en:peanuts")),
          Allergen(
              "nuts",
              // Peanuts aren't tree nuts, but someone asking about nuts needs to hear about them.
              listOf("nut", "peanut", "almond", "hazelnut", "walnut", "cashew", "pecan", "pistachio", "macadamia", "brazil nut"),
              listOf("en:nuts", "en:peanuts"),
              listOf("nutmeg", "coconut", "butternut", "doughnut", "donut"),
          ),
          Allergen(
              "milk",
              listOf("milk", "lactose", "cream", "butter", "cheese", "whey", "casein", "yoghurt", "yogurt", "dairy"),
              listOf("en:milk"),
              listOf(
                  "cocoa butter", "peanut butter", "shea butter", "nut butter", "coconut milk", "coconut cream",
                  "cream of tartar", "almond milk", "oat milk", "soya milk", "soy milk", "rice milk", "milk thistle",
              ),
          ),
          Allergen("gluten", listOf("gluten", "wheat", "barley", "rye", "oat", "spelt", "kamut"), listOf("en:gluten")),
          Allergen("eggs", listOf("egg"), listOf("en:eggs")),
          Allergen("soya", listOf("soya", "soy", "soybean"), listOf("en:soybeans")),
          Allergen("fish", listOf("fish", "anchovy", "salmon", "tuna", "cod"), listOf("en:fish")),
          Allergen(
              "shellfish",
              listOf("shellfish", "crustacean", "prawn", "shrimp", "crab", "lobster", "mussel", "oyster", "mollusc", "squid"),
              listOf("en:crustaceans", "en:molluscs"),
          ),
          Allergen("sesame", listOf("sesame"), listOf("en:sesame-seeds")),
          Allergen("mustard", listOf("mustard"), listOf("en:mustard")),
          Allergen("celery", listOf("celery", "celeriac"), listOf("en:celery")),
          Allergen("lupin", listOf("lupin"), listOf("en:lupin")),
          Allergen("sulphites", listOf("sulphite", "sulfite", "sulphur dioxide"), listOf("en:sulphur-dioxide-and-sulphites")),
      )

  private val SYNONYMS =
      mapOf(
          "nut" to "nuts", "tree nuts" to "nuts", "dairy" to "milk", "lactose" to "milk", "wheat" to "gluten",
          "egg" to "eggs", "soy" to "soya", "peanut" to "peanuts", "crustaceans" to "shellfish",
          "seafood" to "shellfish", "sesame seeds" to "sesame", "sulfites" to "sulphites",
      )

  private fun allergenFor(query: String): Allergen {
    val q = query.lowercase().trim().removePrefix("any ").trim()
    val key = SYNONYMS[q] ?: q
    return ALLERGENS.firstOrNull { it.name == key }
        ?: ALLERGENS.firstOrNull { a -> a.terms.any { it == key || it + "s" == key } }
        ?: Allergen(q, listOf(q.removeSuffix("s")), emptyList())
  }

  /** Pattern for any of [terms] as a word, plural allowed ("almonds", "hazelnuts", "eggs"). */
  private fun termPattern(terms: List<String>): String =
      terms.joinToString("|", "(?:", ")") { words(it) + "(?:e?s)?" }

  /** [phrase] as a regex, any run of spaces between its words. (Regex.escape quotes the whole
   * string, so spaces can't be replaced inside it.) */
  private fun words(phrase: String): String = phrase.split(' ').joinToString("\\s+") { Regex.escape(it) }

  /**
   * The answer to "does it contain [query]?" from the label text [label] (null if not read) and
   * the looked-up [product] (null if not looked up).
   */
  fun allergenAnswer(query: String, label: String?, product: OffProduct?): String {
    val a = allergenFor(query)
    val t = termPattern(a.terms)
    val opts = setOf(RegexOption.IGNORE_CASE)
    val text = label.orEmpty().replace(Regex("\\s+"), " ")
    // Masked copy for searching: look-alikes ("cocoa butter") blanked out, same length.
    val masked =
        a.notTerms.fold(text) { acc, n ->
          acc.replace(Regex("\\b" + words(n) + "\\b", opts)) { " ".repeat(it.value.length) }
        }
    val free =
        Regex("\\b$t[- ]free\\b|free\\s+from\\s+(?:\\w+\\s+){0,3}?$t\\b|\\bno\\s+(?:added\\s+)?$t\\b|does\\s+not\\s+contain\\s+(?:\\w+\\s+){0,2}?$t\\b", opts)
            .find(masked)
    val textForPresence = free?.let { blank(masked, it.range) } ?: masked
    val traces = Regex("(?:may|might|can)\\s+(?:also\\s+)?contain[^.]{0,80}?\\b$t\\b|traces?\\s+of[^.]{0,60}?\\b$t\\b|(?:handles|factory|facility|environment)[^.]{0,80}?\\b$t\\b", opts)
        .find(textForPresence)
    val withoutTraces = traces?.let { blank(textForPresence, it.range) } ?: textForPresence
    // A term in the same sentence as "gluten free" ("Gluten free oat bars") is part of that claim.
    val freeSentence = free?.let { sentenceRange(text, it.range) }
    val present =
        Regex("\\b$t\\b", opts).findAll(withoutTraces).firstOrNull { m -> freeSentence == null || m.range.first !in freeSentence }
    val productHas = product != null && product.allergenTags.any { it in a.tags }
    val productTraces = product != null && product.traceTags.any { it in a.tags }

    val parts = mutableListOf<String>()
    when {
      present != null -> parts += "Yes. The label mentions ${present.value.lowercase().trim()}."
      productHas -> parts += "Yes. Open Food Facts lists ${a.name} as an allergen in this product."
    }
    if (present != null && productHas) parts += "Open Food Facts lists ${a.name} too."
    if (parts.isEmpty() && (traces != null || productTraces)) {
      parts += if (traces != null) "It may contain ${a.name}. The label says: ${sentenceAround(text, traces.range)}"
               else "It may contain ${a.name}. Open Food Facts lists it as a possible trace."
    } else if (parts.isNotEmpty() && traces != null && present == null) {
      parts += "The label also says: ${sentenceAround(text, traces.range)}"
    }
    if (parts.isEmpty() && free != null) {
      parts += "The label says: ${sentenceAround(text, free.range)}"
    }
    if (parts.isEmpty()) {
      val where =
          when {
            label != null && product != null -> "on the label or in the product data"
            label != null -> "on the part of the label I read"
            product != null -> "in the product data"
            else -> "anywhere yet"
          }
      parts += "I couldn't find ${a.name} $where. That doesn't mean it's free from ${a.name}. " +
          "Check the whole label, or ask someone to check."
    }
    return parts.joinToString(" ")
  }

  /** "Allergy advice" without a question: what the label and the product data say. */
  fun allergenSummary(lines: List<LabelLine>?, product: OffProduct?): String? {
    val parts = mutableListOf<String>()
    val fromLabel = lines?.let { section(it, LabelSection.ALLERGENS) }
    val mayContain =
        lines?.map { it.text }?.joinToString(" ")?.let { Regex("may contain[^.]{0,80}", RegexOption.IGNORE_CASE).find(it)?.value }
    if (fromLabel != null) parts += "Allergy advice on the label: ${fromLabel.trimEnd('.')}."
    else if (mayContain != null) parts += "The label says: ${mayContain.trim().trimEnd('.')}."
    if (product != null && product.allergens.isNotEmpty()) {
      parts += "Open Food Facts lists ${listWords(product.allergens)}."
    }
    if (product != null && product.traces.isNotEmpty()) {
      parts += "It may contain traces of ${listWords(product.traces)}."
    }
    return parts.joinToString(" ").ifEmpty { null }
  }

  fun listWords(words: List<String>): String =
      when (words.size) {
        0 -> ""
        1 -> words[0]
        else -> words.dropLast(1).joinToString(", ") + " and " + words.last()
      }

  private fun sentenceRange(text: String, range: IntRange): IntRange {
    val start = text.lastIndexOf('.', range.first).let { if (it < 0) 0 else it + 1 }
    val end = text.indexOf('.', range.last).let { if (it < 0) text.length else it + 1 }
    return start until end
  }

  private fun blank(s: String, r: IntRange): String = s.replaceRange(r, " ".repeat(r.last - r.first + 1))

  /** The sentence of [text] that holds [range], trimmed. */
  private fun sentenceAround(text: String, range: IntRange): String = text.substring(sentenceRange(text, range)).trim()
}
