/*
 * FoodCheck - "Is this OK for me?": a pack's ingredients and allergy advice against my allergens
 *
 * Roadmap V2 food check. Pure: the sides of the pack read so far (newest first), the user's list,
 * and Open Food Facts data if the user already looked the barcode up. The answer names exactly what
 * was found and where: "Contains milk: it says whey powder in the ingredients." "May contain" and
 * "made in a factory that handles ..." lines are reported as such, never as "contains".
 *
 * Honesty rules (ROADMAP ground rules, value-strategy 7):
 * - It never says "safe" or "allergen free". With a complete ingredients list and nothing found,
 *   it says "I didn't find your allergens in the ingredients I could read. Check the pack if you're
 *   unsure."
 * - It abstains when the read is partial: no ingredients heading, a line running off the photo, a
 *   blurred line, or a list that stops mid-way (no full stop at the end of the text, a trailing
 *   comma, an open bracket). It still names allergens it did find, since hiding one would be worse,
 *   but it never says the rest are absent.
 * - Open Food Facts can agree, but never overrides the pack. When they disagree, it says so and
 *   says the pack wins.
 */

import Foundation

enum FoodReadState: Equatable, Sendable {
  enum Reason: Equatable, Sendable {
    /// A line of the list runs into the edge of the photo.
    case cutOff
    /// A line was read with low confidence.
    case unclear
    /// The list stops mid-way.
    case unfinished
  }

  case complete
  case partial(Reason)
  /// No ingredients heading on any side read.
  case notFound
}

struct FoodFinding: Equatable, Sendable {
  enum Place: Equatable, Sendable {
    case ingredients
    case allergyAdvice
    /// "May contain", "made in a factory that handles ...".
    case warning
  }

  var allergen: FoodAllergen
  var place: Place
  /// Ingredient items as printed ("whey powder"), or the warning sentence.
  var evidence: [String]
}

struct FoodCheckReport: Equatable, Sendable {
  var state: FoodReadState
  var contains: [FoodFinding]
  var mayContain: [FoodFinding]
  /// Spoken lines about Open Food Facts, empty when it wasn't looked up.
  var openFoodFacts: [String]
  var spoken: String
}

enum FoodCheck {
  /// Below this OCR confidence a line counts as unclear (FramingAdvisor.lowConfidence).
  static let clearConfidence: Float = 0.5
  /// Ingredient lists can be long; this many lines at most.
  static let maxIngredientLines = 40

  static let nothingFound = "I didn't find your allergens in the ingredients I could read. Check the pack if you're unsure."
  static let askAgain = "Move the pack so all the ingredients are in view, hold it steady, and say food check again."
  static let turnForIngredients = "Turn the pack until I can see the word Ingredients, then say food check again."

  // MARK: Patterns

  private static let sentenceBreak = LabelsRegex("(?<=[.!?])\\s+(?=\\S)")
  private static let whitespace = LabelsRegex("\\s+")
  private static let brokenWord = LabelsRegex("([a-z])- ([a-z])")
  private static let trace = LabelsRegex(
    "\\b(?:may|might|can|could)\\s+(?:also\\s+)?contain\\b|\\btraces?\\s+of\\b|"
      + "\\b(?:factory|facility|kitchen|bakery|premises|environment|site|line|equipment)\\b[^.]{0,80}?"
      + "\\b(?:handles?|handling|uses?|used|using|process(?:es)?|processing|produces?|also\\s+contains?)\\b|"
      + "\\bnot\\s+suitable\\s+for\\b[^.]{0,60}?\\ballerg|\\bcan(?:not|'t|\u{2019}t)?\\s+guarantee\\b|\\bcannot\\s+guarantee\\b",
    ignoreCase: true)
  /// "For allergens, including cereals containing gluten, see ingredients in bold": about the
  /// layout, not a list of allergens.
  private static let boilerplate = LabelsRegex(
    "see\\s+(?:the\\s+)?ingredients|in\\s+bold|highlighted|underlined|in\\s+capitals|in\\s+capital\\s+letters|\\bfor\\s+allergens\\b",
    ignoreCase: true)
  private static let freeFrom = LabelsRegex("\\bfree\\s+from\\b[^.]*|\\bdoes\\s+not\\s+contain\\b[^.]*", ignoreCase: true)
  private static let containsLine = LabelsRegex("^\\s*contains?\\s*[:\\-]", ignoreCase: true)
  private static let leadingHeading = LabelsRegex(
    "^(?:allergy\\s+(?:advice|information|info)|allergens?|warning|contains?)\\s*[:\\-]?\\s*", ignoreCase: true)

  /// `phrase` as a regex, any run of spaces between its words.
  private static func words(_ phrase: String) -> String {
    phrase.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s+")
  }

  private static func termRegex(_ allergen: FoodAllergen) -> LabelsRegex {
    LabelsRegex("\\b(?:" + allergen.terms.map { words($0) + "(?:e?s)?" }.joined(separator: "|") + ")\\b", ignoreCase: true)
  }

  /// `text` with look-alikes and "X free" / "free from" claims blanked out, same length.
  private static func masked(_ text: String, for allergen: FoodAllergen) -> String {
    var out = freeFrom.replace(in: text) { String(repeating: " ", count: $0.range.length) }
    let t = "(?:" + allergen.terms.map { words($0) + "(?:e?s)?" }.joined(separator: "|") + ")"
    let claims = LabelsRegex("\\b\(t)[- ]free\\b|\\bno\\s+(?:added\\s+)?\(t)\\b|\\bwithout\\s+\(t)\\b", ignoreCase: true)
    out = claims.replace(in: out) { String(repeating: " ", count: $0.range.length) }
    for notTerm in allergen.notTerms {
      out = LabelsRegex("\\b" + words(notTerm) + "\\b", ignoreCase: true).replace(in: out) { String(repeating: " ", count: $0.range.length) }
    }
    return out
  }

  private static func clean(_ text: String) -> String {
    LabelsString.trimmed(brokenWord.replace(in: whitespace.replace(in: text) { _ in " " }) { "\($0.group(1))\($0.group(2))" })
  }

  static func sentences(_ text: String) -> [String] {
    sentenceBreak.replace(in: text) { _ in "\n" }.split(separator: "\n").map { LabelsString.trimmed(String($0)) }.filter { !$0.isEmpty }
  }

  static func isWarning(_ sentence: String) -> Bool { trace.contains(sentence) }

  /// Where the warning's clause starts in `sentence` ("made in a factory that handles nuts" from
  /// "made"), as a UTF-16 offset, or nil if there's no warning.
  private static func warningStart(_ sentence: String) -> Int? {
    guard let hit = trace.first(in: sentence) else { return nil }
    let head = LabelsString.substring(sentence, from: 0, to: hit.start)
    guard LabelsString.length(head) > 0 else { return 0 }
    let clause = [",", ";", ":"].compactMap {
      LabelsString.lastIndex(of: Character($0), in: head, from: LabelsString.length(head) - 1)
    }.max()
    return clause.map { $0 + 1 } ?? 0
  }

  /// The part of a sentence before any warning: "oats, sugar, may contain nuts" gives "oats, sugar,".
  private static func beforeWarning(_ sentence: String) -> String {
    guard let start = warningStart(sentence) else { return sentence }
    return LabelsString.trimmed(LabelsString.substring(sentence, from: 0, to: start))
  }

  // MARK: Reading state

  /// How much of the ingredients list was read.
  static func readState(_ section: LabelSectionLines?) -> FoodReadState {
    guard let section else { return .notFound }
    if section.lines.contains(where: \.touchesEdge) { return .partial(.cutOff) }
    if section.lines.contains(where: { ($0.confidence ?? 1) < clearConfidence }) { return .partial(.unclear) }
    let text = section.text
    if text.isEmpty || section.end == .limit { return .partial(.unfinished) }
    let lower = text.lowercased()
    if [",", "(", "[", "-", "&", ":", "/"].contains(where: { lower.hasSuffix($0) }) || lower.hasSuffix(" and") || lower.hasSuffix(" or") {
      return .partial(.unfinished)
    }
    if text.filter({ $0 == "(" }).count > text.filter({ $0 == ")" }).count
      || text.filter({ $0 == "[" }).count > text.filter({ $0 == "]" }).count
    {
      return .partial(.unfinished)
    }
    // The list ran to the last line of the photo without finishing its sentence.
    // A closing warning ("... salt. May contain nuts") doesn't need its own full stop.
    let parts = sentences(clean(text))
    let listEnded = lower.hasSuffix(".") || (parts.count > 1 && isWarning(parts[parts.count - 1]))
    if section.end == .endOfText, !listEnded { return .partial(.unfinished) }
    return .complete
  }

  // MARK: The check

  /// `sides`: OCR lines of each side read, newest first. `product`: Open Food Facts data, only if
  /// the user looked it up.
  static func check(sides: [[LabelLine]], allergens: [FoodAllergen], product: OffProduct?) -> FoodCheckReport {
    let ingredientsSection = sides.lazy.compactMap {
      LabelText.sectionLines($0, .ingredients, requireHeading: true, maxLines: maxIngredientLines).map(cutAtContains)
    }.first
    let state = readState(ingredientsSection)

    // Ingredients, without "may contain" sentences.
    let ingredients = ingredientsSection.map { clean($0.text) } ?? ""
    let ingredientsSearch = sentences(ingredients).map(beforeWarning).filter { !$0.isEmpty }.joined(separator: " ")

    // Allergy advice: the section and any "Contains: ..." line, without warnings and layout notes.
    var advice: [String] = []
    for side in sides {
      if let section = LabelText.sectionLines(side, .allergens, requireHeading: true) { advice.append(clean(section.text)) }
      for line in side where containsLine.contains(line.text) { advice.append(clean(line.text)) }
    }
    let adviceSearch = advice.flatMap(sentences).filter { !isWarning($0) && !boilerplate.contains($0) }.joined(separator: " ")

    // Warnings from anywhere on the pack.
    var warnings: [String] = []
    for side in sides {
      for sentence in sentences(clean(side.map(\.text).joined(separator: " "))) where isWarning(sentence) {
        let tidy = tidyWarning(sentence)
        if !warnings.contains(tidy) { warnings.append(tidy) }
      }
    }

    var contains: [FoodFinding] = []
    var mayContain: [FoodFinding] = []
    for allergen in allergens {
      let regex = termRegex(allergen)
      let inIngredients = items(regex.all(in: masked(ingredientsSearch, for: allergen)), in: ingredientsSearch)
      if !inIngredients.isEmpty {
        contains.append(FoodFinding(allergen: allergen, place: .ingredients, evidence: inIngredients))
        continue
      }
      let inAdvice = items(regex.all(in: masked(adviceSearch, for: allergen)), in: adviceSearch)
      if !inAdvice.isEmpty {
        contains.append(FoodFinding(allergen: allergen, place: .allergyAdvice, evidence: inAdvice))
        continue
      }
      if let warning = warnings.first(where: { regex.contains(masked($0, for: allergen)) }) {
        mayContain.append(FoodFinding(allergen: allergen, place: .warning, evidence: [warning]))
      }
    }

    let off = product.map { openFoodFactsLines($0, allergens: allergens, contains: contains, mayContain: mayContain, state: state) } ?? []
    let spoken = speak(state: state, allergens: allergens, contains: contains, mayContain: mayContain, openFoodFacts: off)
    return FoodCheckReport(state: state, contains: contains, mayContain: mayContain, openFoodFacts: off, spoken: spoken)
  }

  /// A "Contains: milk, soya" line under the ingredients is allergy advice, not an ingredient.
  private static func cutAtContains(_ section: LabelSectionLines) -> LabelSectionLines {
    guard let cut = section.lines.indices.dropFirst().first(where: { containsLine.contains(section.lines[$0].text) }) else {
      return section
    }
    // texts holds the heading line's rest (if any) and then one entry per following line.
    let offset = section.texts.count - (section.lines.count - 1)
    return LabelSectionLines(
      texts: Array(section.texts.prefix(max(0, cut - 1 + offset))), lines: Array(section.lines.prefix(cut)), end: .heading)
  }

  /// The ingredient item around each hit, as printed: "whey powder", "wheat flour", "butter (milk)".
  /// An item inside a longer one ("butter" in "butter (milk)") is said once, as the longer one.
  private static func items(_ hits: [LabelsRegex.Hit], in text: String) -> [String] {
    var out: [String] = []
    for hit in hits {
      let item = item(around: hit.range, in: text) ?? hit.value
      let spoken = LabelsString.trimmed(whitespace.replace(in: item.lowercased()) { _ in " " })
      if spoken.isEmpty || out.contains(where: { $0.contains(spoken) }) { continue }
      if let i = out.firstIndex(where: { spoken.contains($0) }) {
        out[i] = spoken
      } else {
        out.append(spoken)
      }
    }
    return out
  }

  private static let delimiters = Set(",;()[]:.".utf16)

  private static func item(around range: NSRange, in text: String) -> String? {
    let units = Array(text.utf16)
    func bounds(_ from: Int, _ to: Int) -> (Int, Int) {
      var start = from
      while start > 0, !delimiters.contains(units[start - 1]) { start -= 1 }
      var end = to
      while end < units.count, !delimiters.contains(units[end]) { end += 1 }
      return (start, end)
    }
    var (start, end) = bounds(range.location, range.location + range.length)
    // "whey powder (milk)": a word in brackets belongs to the item before it.
    if start > 0, units[start - 1] == UInt16(UInt8(ascii: "(")), end < units.count, units[end] == UInt16(UInt8(ascii: ")")) {
      let (outerStart, _) = bounds(start - 1, start - 1)
      let outer = LabelsString.trimmed(LabelsString.substring(text, from: outerStart, to: start - 1))
      if !outer.isEmpty {
        start = outerStart
        end += 1
      }
    }
    var item = LabelsString.trimmed(LabelsString.substring(text, from: start, to: end))
    item = LabelsString.trimmed(leadingHeading.replace(in: item) { _ in "" })
    for prefix in ["and ", "or ", "with "] where item.lowercased().hasPrefix(prefix) { item = String(item.dropFirst(prefix.count)) }
    item = LabelsString.trim(item, " *-")
    guard !item.isEmpty, item.split(separator: " ").count <= 6 else { return nil }
    return item
  }

  /// A warning sentence as spoken: no heading, no full stop, not too long.
  private static func tidyWarning(_ sentence: String) -> String {
    let clause = LabelsString.substring(sentence, from: warningStart(sentence) ?? 0)
    var s = LabelsString.trimmed(leadingHeading.replace(in: LabelsString.trimmed(clause)) { _ in "" })
    s = LabelsString.trimEnd(s, ". ")
    if LabelsString.length(s) > 140 {
      let cut = LabelsString.substring(s, from: 0, to: 140)
      s = cut.split(separator: " ").dropLast().joined(separator: " ")
    }
    guard let first = s.first else { return s }
    return first.lowercased() + s.dropFirst()
  }

  // MARK: Open Food Facts (corroborates, never overrides)

  static func openFoodFactsLines(
    _ product: OffProduct, allergens: [FoodAllergen], contains: [FoodFinding], mayContain: [FoodFinding], state: FoodReadState
  ) -> [String] {
    var agrees: [FoodAllergen] = []
    var lines: [String] = []
    for allergen in allergens {
      let listed = product.allergenTags.contains { allergen.tags.contains($0) }
      let trace = product.traceTags.contains { allergen.tags.contains($0) }
      let onPack = contains.contains { $0.allergen == allergen }
      let warnedOnPack = mayContain.contains { $0.allergen == allergen }
      switch (onPack, listed) {
      case (true, true):
        agrees.append(allergen)
      case (true, false):
        if !trace { lines.append("Open Food Facts doesn't list \(allergen.spoken), but the pack wins: go by the pack.") }
      case (false, true):
        if state == .complete {
          lines.append(
            "Open Food Facts lists \(allergen.spoken), but I didn't find it on the pack. The pack wins, but check the pack carefully, or ask someone.")
        } else {
          lines.append("Open Food Facts lists \(allergen.spoken). The pack is what counts, so I still need to read its ingredients.")
        }
      case (false, false):
        if trace, !warnedOnPack {
          lines.append("Open Food Facts lists \(allergen.spoken) as a possible trace, but I didn't see that on the pack. The pack wins, but check it.")
        }
      }
    }
    if !agrees.isEmpty { lines.insert("Open Food Facts lists \(FoodAllergens.spokenList(agrees)) too.", at: 0) }
    return lines
  }

  // MARK: Wording

  private static func speak(
    state: FoodReadState, allergens: [FoodAllergen], contains: [FoodFinding], mayContain: [FoodFinding], openFoodFacts: [String]
  ) -> String {
    var parts: [String] = []
    for finding in contains {
      let what = LabelText.listWords(Array(finding.evidence.prefix(3)))
      switch finding.place {
      case .ingredients: parts.append("Contains \(finding.allergen.spoken): it says \(what) in the ingredients.")
      case .allergyAdvice, .warning: parts.append("Contains \(finding.allergen.spoken): the allergy advice says \(what).")
      }
    }
    // One line per warning sentence, naming each of my allergens it covers.
    var bySentence: [(String, [FoodAllergen])] = []
    for finding in mayContain {
      let sentence = finding.evidence.first ?? ""
      if let i = bySentence.firstIndex(where: { $0.0 == sentence }) {
        bySentence[i].1.append(finding.allergen)
      } else {
        bySentence.append((sentence, [finding.allergen]))
      }
    }
    for (sentence, list) in bySentence {
      parts.append("May contain \(FoodAllergens.spokenList(list)): the pack says, \(sentence).")
    }
    parts.append(contentsOf: openFoodFacts)

    let foundAny = !contains.isEmpty || !mayContain.isEmpty
    switch state {
    case .complete:
      let notFound = allergens.filter { a in !contains.contains { $0.allergen == a } && !mayContain.contains { $0.allergen == a } }
      if !foundAny {
        parts.append(nothingFound)
      } else if !notFound.isEmpty {
        parts.append("I didn't find \(FoodAllergens.spokenList(notFound)) in the ingredients I could read. Check the pack if you're unsure.")
      }
    case .partial(let reason):
      let why: String
      switch reason {
      case .cutOff: why = "The ingredients run off the edge of the picture"
      case .unclear: why = "Some of the ingredients are too blurred to read"
      case .unfinished: why = "The ingredients look cut off"
      }
      parts.append(foundAny ? "\(why), so there may be more. \(askAgain)" : "\(why), so I can't check them. \(askAgain)")
    case .notFound:
      parts.append(
        foundAny
          ? "I couldn't find the ingredients list, so I can't check the rest. \(turnForIngredients)"
          : "I can't find the ingredients on this side, so I can't check it. \(turnForIngredients)")
    }
    return parts.joined(separator: " ")
  }
}
