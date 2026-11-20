/*
 * MedicineCheck - does this label or product look like medicine?
 *
 * Port of Android's tools/labels/MedicineCheck.kt. ROADMAP rule: for medicine the label reader gives
 * the name only and never reads a dose. A wrong dose read aloud can hurt someone, so this leans
 * towards "medicine": one strong sign is enough (tablets, capsules, dosage, pharmacy, prescription,
 * "each tablet contains", a common drug name, or an Open Food Facts category such as medicines or
 * dietary supplements), or two different weak signs (a strength in mg or mcg, "take 2", "every 4
 * hours", "daily"). Food nutrition panels give at most one weak sign ("sodium 400mg"; "% daily value"
 * doesn't count). `nameOnly` strips strengths and counts from a medicine's name, so "Paracetamol
 * 500 mg Tablets" is said as "Paracetamol Tablets".
 *
 * The expiry date of a medicine is given (an out-of-date medicine matters), but only when it was read
 * clearly, and always with a reminder to have it checked: `expiry`. A date on a line OCR wasn't sure
 * of is not said at all; a wrong date on a medicine is as bad as no date.
 */

import Foundation

enum MedicineCheck {
  private static let strong: [LabelsRegex] = [
    LabelsRegex("\\b(TABLETS?|CAPSULES?|CAPLETS?|LOZENGES?|PESSAR(Y|IES)|SUPPOSITOR(Y|IES)|SOFTGELS?|GELCAPS?)\\b"),
    LabelsRegex("\\b(DOSAGE|DOSES?|DOSING|OVERDOSE)\\b"),
    LabelsRegex("\\b(PHARMACY|PHARMACIST|PHARMACEUTICAL|PRESCRIPTION|PRESCRIBED|POM|PRESCRIBER)\\b"),
    LabelsRegex("PATIENT INFORMATION|PACKAGE LEAFLET|ACTIVE INGREDIENTS?|EACH (TABLET|CAPSULE|CAPLET|SACHET|DOSE|\\d+ ?ML) CONTAINS"),
    LabelsRegex("DO NOT EXCEED|ORAL (SUSPENSION|SOLUTION)|EYE DROPS|NASAL SPRAY|INHALER|\\bMEDICINES?\\b|\\bMEDICATION\\b"),
    LabelsRegex(
      "\\b(PARACETAMOL|ACETAMINOPHEN|IBUPROFEN|ASPIRIN|CODEINE|NAPROXEN|LORATADINE|CETIRIZINE|"
        + "FEXOFENADINE|CHLORPHENAMINE|DIPHENHYDRAMINE|OMEPRAZOLE|LANSOPRAZOLE|AMOXICILLIN|"
        + "METFORMIN|SIMVASTATIN|ATORVASTATIN|AMLODIPINE|LEVOTHYROXINE|SERTRALINE|DIAZEPAM|"
        + "TRAMADOL|MORPHINE|INSULIN|ANTIHISTAMINE|DECONGESTANT|ANALGESIC|LAXATIVE)\\b"),
  ]

  private static let weak: [LabelsRegex] = [
    LabelsRegex("\\d+(\\.\\d+)? ?(MG|MCG|\u{039C}G|\u{00B5}G)\\b"),
    LabelsRegex("\\bTAKE (\\d|ONE|TWO|THREE|FOUR|HALF)\\b"),
    LabelsRegex("\\bTAKE\\b(?! CARE| AWAY| OUT| HOME)"),
    LabelsRegex("TIMES (A|PER|EACH) DAY|EVERY \\d+ ?(-|TO) ?\\d* ?HOURS?|EVERY \\d+ HOURS?|ONCE (A|PER) DAY|TWICE (A|PER) DAY"),
    LabelsRegex("\\bDAILY\\b(?! VALUE| INTAKE| REFERENCE)"),
    LabelsRegex("\\bADULTS? AND CHILDREN\\b|CHILDREN UNDER \\d+"),
  ]

  private static let medicineCategories = [
    "medicine", "drug", "pharma", "dietary-supplement", "food-supplement", "supplements", "vitamins",
  ]

  /// True if `text` (label text, any case) or `categoryTags` (Open Food Facts) suggest medicine.
  static func looksLikeMedicine(_ text: String, categoryTags: [String] = []) -> Bool {
    if categoryTags.contains(where: { tag in medicineCategories.contains { tag.lowercased().contains($0) } }) { return true }
    let up = text.uppercased()
    if strong.contains(where: { $0.contains(up) }) { return true }
    return weak.filter { $0.contains(up) }.count >= 2
  }

  private static let unitWord = LabelsRegex("(MG|MCG|\u{00B5}G|\u{039C}G|G|ML|L|IU|%|X|PER|EACH)", ignoreCase: true)

  /// A medicine's name with every number and the unit after it removed: no strengths, no counts.
  /// "Paracetamol 500 mg Tablets" -> "Paracetamol Tablets"; "Ibuprofen 200mg x 16" -> "Ibuprofen".
  static func nameOnly(_ name: String) -> String {
    let words = name.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    var out: [String] = []
    var dropUnit = false
    for word in words {
      if word.contains(where: { $0.isNumber }) {
        dropUnit = true
        continue
      }
      if dropUnit, unitWord.matches(LabelsString.trim(word, ",./")) { continue }
      dropUnit = false
      if word == "/" || word == "x" || word == "X" { continue }
      out.append(word)
    }
    let joined = LabelsString.trim(out.joined(separator: " "), " ,-/")
    return joined.isEmpty ? "a medicine" : joined
  }

  /// OCR line confidence below this, on a line with the date, means the date isn't read out.
  static let minDateConfidence: Float = 0.8

  static let expiryCheck = "Please have a pharmacist or a trusted person check the date before you take it."
  static let expiryUnsure =
    "I can see a date on this medicine, but I can't read it for sure. Please ask a pharmacist or a trusted person to check it."

  /// What to say for "when does it expire" on medicine. `dateAnswer` is the plain answer
  /// (LabelDates.answer), nil if no date was found. `dateLineConfidences` are the OCR confidences of
  /// the lines the date came from (nil = the engine gave none). Unsure: no figure. Sure: the date and
  /// `expiryCheck`. Nothing found: nil, so the caller says "turn it".
  static func expiry(_ dateAnswer: String?, dateLineConfidences: [Float?]) -> String? {
    guard let dateAnswer else { return nil }
    if dateLineConfidences.contains(where: { $0 == nil || $0! < minDateConfidence }) { return expiryUnsure }
    return "\(dateAnswer) \(expiryCheck)"
  }
}
