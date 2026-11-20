/*
 * LabelsGrammar - what the user says inside the label reader
 *
 * Port of Android's tools/labels/LabelsGrammar.kt. Commands: scan, look it up, read the label, read
 * it all, when does it expire, cooking instructions, ingredients, allergens / does it contain nuts,
 * what is it, stop scanning, and dose questions (which the tool always declines). Ordered rules,
 * specific phrases before the short words inside them.
 *
 * Text is normalised first (LabelsPhrases): lower case, apostrophes closed up as VoiceCommandParser
 * does ("what's" is "whats"), punctuation out, the "reader, ..." address and filler words dropped.
 * Rules then match the whole phrase, except doses, dates, cooking and ingredients, which match
 * a key word anywhere: a dose question must never slip through as something else.
 * The tool's opening phrases are ToolID.labels.openPhrases (SpeakUpTool.swift), not here.
 */

import Foundation

/// The shared normalisation for the tools' grammars, Android's Phrases.normalize with apostrophes
/// closed up as iOS's VoiceCommandParser does.
enum LabelsPhrases {
  /// Words people add around a command that don't change it. Removed anywhere, as on Android.
  static let fillers = [
    "please", "um", "umm", "uh", "er", "erm", "okay", "ok", "alright", "right", "so", "can you", "could you", "would you",
    "will you", "i want you to", "id like you to", "just", "now", "thanks", "thank you",
  ]

  private static let address = LabelsRegex("^(hey |ok |okay )?(the )?(book reader|reader|readers|glasses|app|assistant|speakup|speak up) (?=\\S)")
  private static let fillerPatterns = fillers.map { LabelsRegex("(^| )" + NSRegularExpression.escapedPattern(for: $0) + "(?= |$)") }
  private static let spaces = LabelsRegex("\\s+")
  private static let nonWord = LabelsRegex("[^a-z0-9 ]")

  static func normalize(_ transcript: String) -> String {
    var t = transcript.lowercased().replacingOccurrences(of: "\u{2019}", with: "").replacingOccurrences(of: "'", with: "")
    t = nonWord.replace(in: t) { _ in " " }
    t = LabelsString.trimmed(spaces.replace(in: t) { _ in " " })
    t = LabelsString.trimmed(address.replace(in: t) { _ in "" })
    for filler in fillerPatterns { t = filler.replace(in: t) { _ in " " } }
    return LabelsString.trimmed(spaces.replace(in: t) { _ in " " })
  }
}

/// Commands inside the label reader.
enum LabelsCommand: Equatable, Sendable {
  /// Look for a barcode (again).
  case scan
  case stopScan
  /// Look the decoded barcode up on Open Food Facts.
  case lookUp
  /// Read the label word for word.
  case readLabel
  /// Read all of it (also: carry on with the whole label after a jump).
  case readAll
  case expiry
  case cooking
  case ingredients
  /// "allergens" (query nil) or "does it contain nuts" (query "nuts").
  case allergens(String?)
  /// The product's name again.
  case name
  /// Anything about how much medicine to take. Always declined.
  case dose
}

enum LabelsGrammar {
  private static let it = "(?:it|this|that|they|these|them)"

  private static let notAQuery: Set<String> = ["allergens", "allergies", "allergen", "anything", "any allergens", "allergy"]

  private static let allergenQuery: [LabelsRegex] = [
    LabelsRegex("^(?:does|do|did) \(it) (?:contain|have|include|got)(?: any| some)? (.+?)(?: in (?:it|them))?$"),
    LabelsRegex("^(?:is|are) there (?:any |some )?(.+?) in \(it)$"),
    LabelsRegex("^(?:is|are) \(it) (.+?)[ -]free$"),
    LabelsRegex("^(?:has|have) \(it) got (?:any )?(.+?)(?: in (?:it|them))?$"),
    LabelsRegex("^any (.+?) in \(it)$"),
    LabelsRegex("^(?:can|could|would) \(it) (?:have|contain) (?:any )?(.+?)$"),
  ]

  private static let dose = LabelsRegex(
    "\\b(?:doses?|dosage|dosing)\\b|how (?:many|much|often) (?:should|do|can|must|shall|could) (?:i|you|we|he|she|they) "
      + "(?:take|have|give|use)|how many (?:tablets|pills|capsules|caplets|spoons|teaspoons)|how often|"
      + "when (?:should|can|do) (?:i|you) take|can i (?:take|have) (?:another|more|two|2|one|1)|"
      + "directions for use|how (?:do|should) (?:i|you) take|how much to take|how to take")

  private static let rules: [(LabelsRegex, LabelsCommand)] = [
    (LabelsRegex("^(?:stop|cancel) (?:scanning|looking|searching)$|^cancel$|^never mind$"), .stopScan),
    (
      LabelsRegex(
        "\\blook (?:it|that|this) up\\b|\\blook up\\b|\\bsearch (?:for )?(?:it|that|this)\\b|find (?:the )?product|"
          + "what product is (?:it|this|that)|product (?:name|details|info|information)|search online|check online|"
          + "\\blook it up online\\b"),
      .lookUp
    ),
    (
      LabelsRegex(
        "\\b(?:expire|expires|expired|expiry|expiration|best before|best by|use by|sell by|display until|"
          + "out of date|go off|goes off|gone off|use before|still good|in date|run out|date)\\b"),
      .expiry
    ),
    (
      LabelsRegex("^(?:what (?:are|is) the )?allerg(?:ens?|y|ies)(?: advice| information| info)?$|^any allergens$|^what allergens"),
      .allergens(nil)
    ),
    (
      LabelsRegex(
        "\\bingredients?\\b|whats in (?:it|this|that)|what is in (?:it|this|that)|whats it made (?:of|from)|what is it made (?:of|from)"),
      .ingredients
    ),
    (
      LabelsRegex(
        "\\b(?:cook|cooking|cooked|heat (?:it|this) up|heat (?:it|this)|heating|prepare|preparation|microwave|oven|instructions|directions)\\b"
      ),
      .cooking
    ),
    (
      LabelsRegex(
        "^(?:read (?:it )?all(?: of it)?|read everything|read the (?:whole|entire|full|rest of the) (?:label|thing|packet|pack|box|text)|"
          + "read (?:the )?rest|read the lot|read it all out|everything)$"),
      .readAll
    ),
    (
      LabelsRegex(
        "^(?:read(?: (?:the|this|its))? ?(?:label|packet|pack|box|tin|can|jar|bottle|carton|text|writing)?|read it(?: out)?|read it to me|what does it say)$"
      ),
      .readLabel
    ),
    (
      LabelsRegex(
        "^(?:what is it|whats it called|what is it called|what was it|whats the name|what is the name|name|say the name(?: again)?|which product|which product is it)$"
      ),
      .name
    ),
    (
      LabelsRegex(
        "^(?:scan|scan (?:this|it|that|again|the barcode|a barcode|the code|this code|another|another one|the next one|next)|"
          + "what(?:s| is) (?:this|that)|try again|look again|start again|new (?:product|item|one)|next(?: one| product| item)?)$"),
      .scan
    ),
  ]

  /// A command inside the tool, or nil. Takes the raw transcript.
  static func parse(_ transcript: String) -> LabelsCommand? {
    parseNormalized(LabelsPhrases.normalize(transcript))
  }

  static func parseNormalized(_ normalized: String) -> LabelsCommand? {
    let t = LabelsString.trimmed(normalized)
    guard !t.isEmpty else { return nil }
    // Doses first, before anything else can claim the words.
    if dose.contains(t) { return .dose }
    // "does it contain nuts" before the general rules.
    for regex in allergenQuery {
      guard let m = regex.first(in: t) else { continue }
      var q = LabelsString.trimmed(m.group(1))
      if q.hasPrefix("any ") { q = LabelsString.trimmed(String(q.dropFirst(4))) }
      if q.split(separator: " ").count > 4 { continue }
      return .allergens(notAQuery.contains(q) ? nil : q)
    }
    for (regex, command) in rules where regex.contains(t) { return command }
    return nil
  }
}
