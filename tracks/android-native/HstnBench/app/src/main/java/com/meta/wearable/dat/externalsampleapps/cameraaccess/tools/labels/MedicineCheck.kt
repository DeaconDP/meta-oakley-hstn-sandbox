// MedicineCheck - does this label or product look like medicine?
//
// ROADMAP rule: for medicine the label reader gives the name only and never reads a dose. A wrong
// dose read aloud can hurt someone, so this leans towards "medicine": one strong sign is enough
// (tablets, capsules, dosage, pharmacy, prescription, "each tablet contains", a common drug name, or
// an Open Food Facts category such as medicines or dietary supplements), or two different weak signs
// (a strength in mg or mcg, "take 2", "every 4 hours", "daily"). Food nutrition panels give at most
// one weak sign ("sodium 400mg"; "% daily value" doesn't count). [nameOnly] strips strengths and
// counts from a medicine's name, so "Paracetamol 500 mg Tablets" is said as "Paracetamol Tablets".
// Pure Kotlin, JVM-tested.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.labels

object MedicineCheck {

  private val STRONG =
      listOf(
          Regex("\\b(TABLETS?|CAPSULES?|CAPLETS?|LOZENGES?|PESSAR(Y|IES)|SUPPOSITOR(Y|IES)|SOFTGELS?|GELCAPS?)\\b"),
          Regex("\\b(DOSAGE|DOSES?|DOSING|OVERDOSE)\\b"),
          Regex("\\b(PHARMACY|PHARMACIST|PHARMACEUTICAL|PRESCRIPTION|PRESCRIBED|POM|PRESCRIBER)\\b"),
          Regex("PATIENT INFORMATION|PACKAGE LEAFLET|ACTIVE INGREDIENTS?|EACH (TABLET|CAPSULE|CAPLET|SACHET|DOSE|\\d+ ?ML) CONTAINS"),
          Regex("DO NOT EXCEED|ORAL (SUSPENSION|SOLUTION)|EYE DROPS|NASAL SPRAY|INHALER|\\bMEDICINES?\\b|\\bMEDICATION\\b"),
          Regex(
              "\\b(PARACETAMOL|ACETAMINOPHEN|IBUPROFEN|ASPIRIN|CODEINE|NAPROXEN|LORATADINE|CETIRIZINE|" +
                  "FEXOFENADINE|CHLORPHENAMINE|DIPHENHYDRAMINE|OMEPRAZOLE|LANSOPRAZOLE|AMOXICILLIN|" +
                  "METFORMIN|SIMVASTATIN|ATORVASTATIN|AMLODIPINE|LEVOTHYROXINE|SERTRALINE|DIAZEPAM|" +
                  "TRAMADOL|MORPHINE|INSULIN|ANTIHISTAMINE|DECONGESTANT|ANALGESIC|LAXATIVE)\\b",
          ),
      )

  private val WEAK =
      listOf(
          Regex("\\d+(\\.\\d+)? ?(MG|MCG|ΜG|µG)\\b"),
          Regex("\\bTAKE (\\d|ONE|TWO|THREE|FOUR|HALF)\\b"),
          Regex("\\bTAKE\\b(?! CARE| AWAY| OUT| HOME)"),
          Regex("TIMES (A|PER|EACH) DAY|EVERY \\d+ ?(-|TO) ?\\d* ?HOURS?|EVERY \\d+ HOURS?|ONCE (A|PER) DAY|TWICE (A|PER) DAY"),
          Regex("\\bDAILY\\b(?! VALUE| INTAKE| REFERENCE)"),
          Regex("\\bADULTS? AND CHILDREN\\b|CHILDREN UNDER \\d+"),
      )

  private val MEDICINE_CATEGORIES =
      listOf("medicine", "drug", "pharma", "dietary-supplement", "food-supplement", "supplements", "vitamins")

  /** True if [text] (label text, any case) or [categoryTags] (Open Food Facts) suggest medicine. */
  fun looksLikeMedicine(text: String, categoryTags: List<String> = emptyList()): Boolean {
    if (categoryTags.any { tag -> MEDICINE_CATEGORIES.any { tag.lowercase().contains(it) } }) return true
    val up = text.uppercase()
    if (STRONG.any { it.containsMatchIn(up) }) return true
    return WEAK.count { it.containsMatchIn(up) } >= 2
  }

  private val UNIT_WORD = Regex("^(MG|MCG|µG|ΜG|G|ML|L|IU|%|X|PER|EACH)$", RegexOption.IGNORE_CASE)

  /**
   * A medicine's name with every number and the unit after it removed: no strengths, no counts.
   * "Paracetamol 500 mg Tablets" → "Paracetamol Tablets"; "Ibuprofen 200mg x 16" → "Ibuprofen".
   */
  fun nameOnly(name: String): String {
    val words = name.split(Regex("\\s+")).filter { it.isNotEmpty() }
    val out = mutableListOf<String>()
    var dropUnit = false
    for (w in words) {
      if (w.any { it.isDigit() }) {
        dropUnit = true
        continue
      }
      if (dropUnit && UNIT_WORD.matches(w.trim(',', '.', '/'))) continue
      dropUnit = false
      if (w == "/" || w == "x" || w == "X") continue
      out += w
    }
    return out.joinToString(" ").trim(' ', ',', '-', '/').ifEmpty { "a medicine" }
  }
}
