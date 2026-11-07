// LabelsGrammar - what the user says to and inside the label reader
//
// [opens]: the phrases that open this tool from any tool ("scan this", "what's this product", "read
// the label"). GlobalGrammar calls it; add synonyms here, not there. [parse]: commands inside the
// tool: scan, look it up, read the label, read it all, when does it expire, cooking instructions,
// ingredients, allergens / does it contain nuts, what is it, and dose questions (which the tool
// always declines). Ordered rules, specific phrases before the short words inside them, like
// book/VoiceCommands. ToolHub tries [parse] before the global grammar, so "read the label" means
// "read it now" in here, and nothing here claims another tool's opening phrases ("read my mail",
// "watch for", "what colour is this", "is the light on"). Pure Kotlin (no Android imports),
// JVM-tested.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.labels

import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolRequest

/** Commands inside the label reader. */
sealed interface LabelsCommand {
  /** Look for a barcode (again). */
  data object Scan : LabelsCommand
  data object StopScan : LabelsCommand
  /** Look the decoded barcode up on Open Food Facts. */
  data object LookUp : LabelsCommand
  /** Read the label word for word. */
  data object ReadLabel : LabelsCommand
  /** Read all of it (also: carry on with the whole label after a jump). */
  data object ReadAll : LabelsCommand
  data object Expiry : LabelsCommand
  data object Cooking : LabelsCommand
  data object Ingredients : LabelsCommand
  /** "allergens" ([query] null) or "does it contain nuts" ([query] "nuts"). */
  data class Allergens(val query: String?) : LabelsCommand
  /** The product's name again. */
  data object Name : LabelsCommand
  /** Anything about how much medicine to take. Always declined. */
  data object Dose : LabelsCommand
}

object LabelsGrammar {

  private const val THING = "(?:product|item|thing|packet|pack|tin|can|jar|box|bottle|carton|tub)"

  private val OPEN =
      Regex(
          "^(?:scan(?: (?:this|it|that|the barcode|a barcode|the code|this code|the label|this label|$THING))?|" +
              "what(?:'s| is) (?:this|that) $THING|what $THING is (?:this|that)|" +
              "read (?:the|this) (?:label|packet|box|ingredients|tin)|" +
              "(?:open |start |switch to )?(?:the )?(?:label|barcode) (?:reader|scanner)|labels?)$",
      )

  fun opens(normalized: String, @Suppress("UNUSED_PARAMETER") light: String): ToolRequest? =
      if (OPEN.matches(normalized)) ToolRequest(ToolId.LABELS) else null

  private const val IT = "(?:it|this|that|they|these|them)"

  private val NOT_A_QUERY = setOf("allergens", "allergies", "allergen", "anything", "any allergens", "allergy")

  private val ALLERGEN_QUERY =
      listOf(
          Regex("^(?:does|do|did) $IT (?:contain|have|include|got)(?: any| some)? (.+?)(?: in (?:it|them))?$"),
          Regex("^(?:is|are) there (?:any |some )?(.+?) in $IT$"),
          Regex("^(?:is|are) $IT (.+?)[ -]free$"),
          Regex("^(?:has|have) $IT got (?:any )?(.+?)(?: in (?:it|them))?$"),
          Regex("^any (.+?) in $IT$"),
          Regex("^(?:can|could|would) $IT (?:have|contain) (?:any )?(.+?)$"),
      )

  private val RULES: List<Pair<Regex, LabelsCommand>> =
      listOf(
          // Doses first: "how many tablets", "what's the dose", "directions for use".
          Regex(
              "\\b(?:doses?|dosage|dosing)\\b|how (?:many|much|often) (?:should|do|can|must|shall|could) (?:i|you|we|he|she|they) " +
                  "(?:take|have|give|use)|how many (?:tablets|pills|capsules|caplets|spoons|teaspoons)|how often|" +
                  "when (?:should|can|do) (?:i|you) take|can i (?:take|have) (?:another|more|two|2|one|1)|" +
                  "directions for use|how (?:do|should) (?:i|you) take|how much to take|how to take",
          ) to LabelsCommand.Dose,
          Regex("^(?:stop|cancel) (?:scanning|looking|searching)$|^cancel$|^never mind$") to LabelsCommand.StopScan,
          Regex(
              "\\blook (?:it|that|this) up\\b|\\blook up\\b|\\bsearch (?:for )?(?:it|that|this)\\b|find (?:the )?product|" +
                  "what product is (?:it|this|that)|product (?:name|details|info|information)|search online|check online|" +
                  "\\blook it up online\\b",
          ) to LabelsCommand.LookUp,
          Regex(
              "\\b(?:expire|expires|expired|expiry|expiration|best before|best by|use by|sell by|display until|" +
                  "out of date|go off|goes off|gone off|use before|still good|in date|run out|date)\\b",
          ) to LabelsCommand.Expiry,
          Regex("^(?:what (?:are|is) the )?allerg(?:ens?|y|ies)(?: advice| information| info)?$|^any allergens$|^what allergens") to
              LabelsCommand.Allergens(null),
          Regex("\\bingredients?\\b|what's in (?:it|this|that)|what is in (?:it|this|that)|what's it made (?:of|from)|what is it made (?:of|from)") to
              LabelsCommand.Ingredients,
          Regex(
              "\\b(?:cook|cooking|cooked|heat (?:it|this) up|heat (?:it|this)|heating|prepare|preparation|microwave|oven|instructions|directions)\\b",
          ) to LabelsCommand.Cooking,
          Regex(
              "^(?:read (?:it )?all(?: of it)?|read everything|read the (?:whole|entire|full|rest of the) (?:label|thing|packet|pack|box|text)|" +
                  "read (?:the )?rest|read the lot|read it all out|everything)$",
          ) to LabelsCommand.ReadAll,
          Regex("^(?:read(?: (?:the|this|its|it's))? ?(?:label|packet|pack|box|tin|can|jar|bottle|carton|text|writing)?|read it(?: out)?|read it to me|what does it say)$") to
              LabelsCommand.ReadLabel,
          Regex("^(?:what is it|what's it called|what is it called|what was it|what's the name|what is the name|name|say the name(?: again)?|which product|which product is it)$") to
              LabelsCommand.Name,
          Regex(
              "^(?:scan|scan (?:this|it|that|again|the barcode|a barcode|the code|this code|another|another one|the next one|next)|" +
                  "what(?:'s| is) (?:this|that)|try again|look again|start again|new (?:product|item|one)|next(?: one| product| item)?)$",
          ) to LabelsCommand.Scan,
      )

  /** A command inside the tool, or null. [normalized] is Phrases.normalize(transcript). */
  fun parse(normalized: String): LabelsCommand? {
    val t = normalized.trim()
    if (t.isEmpty()) return null
    // "does it contain nuts" before the general rules, but after doses.
    if (RULES[0].first.containsMatchIn(t)) return LabelsCommand.Dose
    for (r in ALLERGEN_QUERY) {
      val m = r.find(t) ?: continue
      val q = m.groupValues[1].trim().removePrefix("any ").trim()
      if (q.split(' ').size > 4) continue
      return LabelsCommand.Allergens(if (q in NOT_A_QUERY) null else q)
    }
    for ((regex, command) in RULES.drop(1)) if (regex.containsMatchIn(t)) return command
    return null
  }
}
