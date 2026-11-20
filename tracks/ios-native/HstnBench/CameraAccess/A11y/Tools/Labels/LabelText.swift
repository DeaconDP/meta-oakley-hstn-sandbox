/*
 * LabelText - finding things in the text of a label
 *
 * Port of Android's tools/labels/LabelText.kt. The label reader reads a label word for word, and
 * also jumps straight to a part of it: ingredients, cooking instructions, allergy advice. Labels
 * are short blocks under headings ("Ingredients:", "Cooking instructions", "Allergy advice"), so a
 * section is the text after its heading up to the next heading of another kind. `nameGuess` takes
 * the biggest print as the product's name. `allergenAnswer` answers "does it contain nuts?" from the
 * label and the Open Food Facts data: it says yes when it finds the allergen, "may contain" when
 * only traces are mentioned, what the label says when it says "free from", and otherwise that it
 * couldn't find it, which is never the same as "no" (ROADMAP: abstain rather than guess).
 */

import Foundation

/// One OCR line in reading order. `height` is its box height in pixels (bigger print, bigger).
/// `confidence` is the line's lowest word confidence, nil if the engine gave none.
struct LabelLine: Equatable, Sendable {
  var text: String
  var height: Double = 0
  var confidence: Float? = nil
  /// The line runs into an edge of the photo, so words may be missing (FramingAdvisor.cutEdges).
  var touchesEdge = false
}

/// A section's lines as found, and why it ended, so food check can tell a whole list from a cut one.
struct LabelSectionLines: Equatable, Sendable {
  enum End: Equatable, Sendable {
    /// Another heading started.
    case heading
    /// The side ran out of lines: the list may go on past the photo.
    case endOfText
    /// The line limit was reached.
    case limit
  }

  /// The text, heading taken off (kept for cooking), one entry per line.
  var texts: [String]
  /// The OCR lines it came from, heading line included.
  var lines: [LabelLine]
  var end: End

  var text: String { LabelsString.trimmed(texts.filter { !LabelsString.trimmed($0).isEmpty }.joined(separator: " ")) }
}

enum LabelSection: Sendable {
  case ingredients
  case cooking
  case allergens
}

enum LabelText {
  private static let headings: [(LabelSection?, LabelsRegex)] = [
    (.ingredients, LabelsRegex("\\bINGREDIENTS?\\b\\s*[:;.\\-]?", ignoreCase: true)),
    (
      .cooking,
      LabelsRegex(
        "\\b(COOKING (INSTRUCTIONS|GUIDELINES|GUIDE|METHOD)|PREPARATION( GUIDELINES| INSTRUCTIONS)?|"
          + "HOW TO (COOK|PREPARE)|TO PREPARE|OVEN( COOK)?|MICROWAVE|HOB|DIRECTIONS)\\b\\s*[:;.\\-]?",
        ignoreCase: true)
    ),
    (.allergens, LabelsRegex("\\b(ALLERGY (ADVICE|INFORMATION|INFO)|ALLERGENS?)\\b\\s*[:;.\\-]?", ignoreCase: true)),
    // Headings that end a section but aren't sections we jump to.
    (
      nil,
      LabelsRegex(
        "\\b(NUTRITION(AL)?( INFORMATION| FACTS)?|TYPICAL VALUES|STORAGE|STORE IN|KEEP REFRIGERATED|"
          + "ONCE OPENED|BEST BEFORE|USE BY|DISPLAY UNTIL|PACKED IN|PRODUCED (IN|BY)|MANUFACTURED|"
          + "RECYCL\\w*|NET (WEIGHT|WT))\\b",
        ignoreCase: true)
    ),
  ]

  private static func heading(_ section: LabelSection) -> LabelsRegex {
    headings.first { $0.0 == section }!.1
  }

  /// At most this many lines are taken for one section.
  static let maxSectionLines = 14

  /// The text of `section` in `lines`, without its heading, or nil if there's no heading. The
  /// cooking section keeps sub-headings (oven, microwave), since they're part of the instructions.
  static func section(_ lines: [LabelLine], _ section: LabelSection) -> String? {
    guard let found = sectionLines(lines, section) else { return nil }
    let joined = found.text
    return joined.isEmpty ? nil : joined
  }

  /// `section` with the lines it came from and how it ended. `requireHeading`: only a real heading
  /// ("Ingredients:"), never a mention ("see ingredients in bold"). `maxLines` caps the lines taken.
  static func sectionLines(
    _ lines: [LabelLine], _ section: LabelSection, requireHeading: Bool = false, maxLines: Int = maxSectionLines
  ) -> LabelSectionLines? {
    let regex = heading(section)
    // A real heading first ("Ingredients:"); a mention ("see ingredients in bold") only if none.
    guard
      let start = lines.firstIndex(where: { isHeading($0.text, regex) })
        ?? (requireHeading ? nil : lines.firstIndex(where: { regex.contains($0.text) }))
    else { return nil }
    let first = lines[start].text
    guard let match = regex.first(in: first) else { return nil }
    let keepHeading = section == .cooking && match.start > 0
    let rest = section == .cooking ? LabelsString.trimmed(first) : LabelsString.trimmed(LabelsString.substring(first, from: match.end))
    var out: [String] = []
    var used = [lines[start]]
    if !rest.isEmpty || keepHeading { out.append(rest) }
    var end = LabelSectionLines.End.endOfText
    for line in lines[(start + 1)...] {
      if out.count >= maxLines {
        end = .limit
        break
      }
      if startsOtherSection(line.text, section) {
        end = .heading
        break
      }
      out.append(LabelsString.trimmed(line.text))
      used.append(line)
    }
    return LabelSectionLines(texts: out, lines: used, end: end)
  }

  private static func startsOtherSection(_ text: String, _ current: LabelSection) -> Bool {
    headings.contains { section, regex in
      if section == current { return false }
      // Stop markers (nutrition, storage, dates) end a section wherever a line starts with them.
      if section == nil { return (regex.first(in: LabelsString.trimmed(text))?.start ?? 99) <= 2 }
      return isHeading(text, regex)
    }
  }

  /// `text` starts with a heading: the words at the start of the line, followed by a colon or
  /// nothing else, or in capitals ("INGREDIENTS Oats..."). "ingredients in bold" isn't one.
  private static func isHeading(_ text: String, _ regex: LabelsRegex) -> Bool {
    let t = LabelsString.trimmed(text)
    guard let m = regex.first(in: t), m.start <= 2 else { return false }
    let word = LabelsString.trimEnd(m.value, " \t\n")
    let after = LabelsString.trimmed(LabelsString.substring(t, from: m.end))
    if word.hasSuffix(":") || word.hasSuffix("-") || after.isEmpty || after.hasPrefix(":") { return true }
    let bare = LabelsString.trimEnd(word, ":;.- ")
    return bare.contains(where: { $0.isLetter }) && bare == bare.uppercased()
  }

  /// The biggest print on the label, as its likely name: up to two lines near the largest size.
  static func nameGuess(_ lines: [LabelLine]) -> String? {
    let candidates = lines.filter { $0.text.filter(\.isLetter).count >= 3 }
    guard let biggest = candidates.map(\.height).max() else { return nil }
    if biggest <= 0 { return LabelsString.trimmed(candidates[0].text) }
    return candidates.filter { $0.height >= biggest * 0.8 }.prefix(2).map { LabelsString.trimmed($0.text) }.joined(separator: " ")
  }

  // MARK: Allergens

  /// `notTerms` contain a term but aren't the allergen ("cocoa butter" isn't milk).
  private struct Allergen {
    var name: String
    var terms: [String]
    var tags: [String]
    var notTerms: [String] = []
  }

  private static let allergens: [Allergen] = [
    Allergen(name: "peanuts", terms: ["peanut", "groundnut", "arachis"], tags: ["en:peanuts"]),
    Allergen(
      name: "nuts",
      // Peanuts aren't tree nuts, but someone asking about nuts needs to hear about them.
      terms: ["nut", "peanut", "almond", "hazelnut", "walnut", "cashew", "pecan", "pistachio", "macadamia", "brazil nut"],
      tags: ["en:nuts", "en:peanuts"],
      notTerms: ["nutmeg", "coconut", "butternut", "doughnut", "donut"]),
    Allergen(
      name: "milk",
      terms: ["milk", "lactose", "cream", "butter", "cheese", "whey", "casein", "yoghurt", "yogurt", "dairy"],
      tags: ["en:milk"],
      notTerms: [
        "cocoa butter", "peanut butter", "shea butter", "nut butter", "coconut milk", "coconut cream", "cream of tartar", "almond milk",
        "oat milk", "soya milk", "soy milk", "rice milk", "milk thistle",
      ]),
    Allergen(name: "gluten", terms: ["gluten", "wheat", "barley", "rye", "oat", "spelt", "kamut"], tags: ["en:gluten"]),
    Allergen(name: "eggs", terms: ["egg"], tags: ["en:eggs"]),
    Allergen(name: "soya", terms: ["soya", "soy", "soybean"], tags: ["en:soybeans"]),
    Allergen(name: "fish", terms: ["fish", "anchovy", "salmon", "tuna", "cod"], tags: ["en:fish"]),
    Allergen(
      name: "shellfish",
      terms: ["shellfish", "crustacean", "prawn", "shrimp", "crab", "lobster", "mussel", "oyster", "mollusc", "squid"],
      tags: ["en:crustaceans", "en:molluscs"]),
    Allergen(name: "sesame", terms: ["sesame"], tags: ["en:sesame-seeds"]),
    Allergen(name: "mustard", terms: ["mustard"], tags: ["en:mustard"]),
    Allergen(name: "celery", terms: ["celery", "celeriac"], tags: ["en:celery"]),
    Allergen(name: "lupin", terms: ["lupin"], tags: ["en:lupin"]),
    Allergen(name: "sulphites", terms: ["sulphite", "sulfite", "sulphur dioxide"], tags: ["en:sulphur-dioxide-and-sulphites"]),
  ]

  private static let synonyms = [
    "nut": "nuts", "tree nuts": "nuts", "dairy": "milk", "lactose": "milk", "wheat": "gluten", "egg": "eggs", "soy": "soya",
    "peanut": "peanuts", "crustaceans": "shellfish", "seafood": "shellfish", "sesame seeds": "sesame", "sulfites": "sulphites",
  ]

  private static func allergen(for query: String) -> Allergen {
    var q = LabelsString.trimmed(query.lowercased())
    if q.hasPrefix("any ") { q = LabelsString.trimmed(String(q.dropFirst(4))) }
    let key = synonyms[q] ?? q
    if let exact = allergens.first(where: { $0.name == key }) { return exact }
    if let byTerm = allergens.first(where: { $0.terms.contains { $0 == key || $0 + "s" == key } }) { return byTerm }
    let singular = q.hasSuffix("s") ? String(q.dropLast()) : q
    return Allergen(name: q, terms: [singular], tags: [])
  }

  /// `phrase` as a regex, any run of spaces between its words.
  private static func words(_ phrase: String) -> String {
    phrase.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s+")
  }

  /// Pattern for any of `terms` as a word, plural allowed ("almonds", "hazelnuts", "eggs").
  private static func termPattern(_ terms: [String]) -> String {
    "(?:" + terms.map { words($0) + "(?:e?s)?" }.joined(separator: "|") + ")"
  }

  private static let whitespace = LabelsRegex("\\s+")

  /// The answer to "does it contain `query`?" from the label text `label` (nil if not read) and the
  /// looked-up `product` (nil if not looked up).
  static func allergenAnswer(_ query: String, label: String?, product: OffProduct?) -> String {
    let a = allergen(for: query)
    let t = termPattern(a.terms)
    let text = whitespace.replace(in: label ?? "") { _ in " " }
    // Masked copy for searching: look-alikes ("cocoa butter") blanked out, same length.
    var masked = text
    for notTerm in a.notTerms {
      masked = LabelsRegex("\\b" + words(notTerm) + "\\b", ignoreCase: true).replace(in: masked) { hit in
        String(repeating: " ", count: hit.range.length)
      }
    }
    let free = LabelsRegex(
      "\\b\(t)[- ]free\\b|free\\s+from\\s+(?:\\w+\\s+){0,3}?\(t)\\b|\\bno\\s+(?:added\\s+)?\(t)\\b|does\\s+not\\s+contain\\s+(?:\\w+\\s+){0,2}?\(t)\\b",
      ignoreCase: true
    ).first(in: masked)
    let textForPresence = free.map { LabelsString.blank(masked, $0.range) } ?? masked
    let traces = LabelsRegex(
      "(?:may|might|can)\\s+(?:also\\s+)?contain[^.]{0,80}?\\b\(t)\\b|traces?\\s+of[^.]{0,60}?\\b\(t)\\b|(?:handles|factory|facility|environment)[^.]{0,80}?\\b\(t)\\b",
      ignoreCase: true
    ).first(in: textForPresence)
    let withoutTraces = traces.map { LabelsString.blank(textForPresence, $0.range) } ?? textForPresence
    // A term in the same sentence as "gluten free" ("Gluten free oat bars") is part of that claim.
    let freeSentence = free.map { sentenceRange(text, $0.range) }
    let present = LabelsRegex("\\b\(t)\\b", ignoreCase: true).all(in: withoutTraces).first { hit in
      freeSentence.map { !$0.contains(hit.start) } ?? true
    }
    let productHas = product?.allergenTags.contains { a.tags.contains($0) } ?? false
    let productTraces = product?.traceTags.contains { a.tags.contains($0) } ?? false

    var parts: [String] = []
    if let present {
      parts.append("Yes. The label mentions \(LabelsString.trimmed(present.value.lowercased())).")
    } else if productHas {
      parts.append("Yes. Open Food Facts lists \(a.name) as an allergen in this product.")
    }
    if present != nil, productHas { parts.append("Open Food Facts lists \(a.name) too.") }
    if parts.isEmpty, traces != nil || productTraces {
      if let traces {
        parts.append("It may contain \(a.name). The label says: \(sentenceAround(text, traces.range))")
      } else {
        parts.append("It may contain \(a.name). Open Food Facts lists it as a possible trace.")
      }
    } else if !parts.isEmpty, let traces, present == nil {
      parts.append("The label also says: \(sentenceAround(text, traces.range))")
    }
    if parts.isEmpty, let free {
      parts.append("The label says: \(sentenceAround(text, free.range))")
    }
    if parts.isEmpty {
      let place: String
      switch (label != nil, product != nil) {
      case (true, true): place = "on the label or in the product data"
      case (true, false): place = "on the part of the label I read"
      case (false, true): place = "in the product data"
      case (false, false): place = "anywhere yet"
      }
      parts.append(
        "I couldn't find \(a.name) \(place). That doesn't mean it's free from \(a.name). Check the whole label, or ask someone to check.")
    }
    return parts.joined(separator: " ")
  }

  private static let mayContain = LabelsRegex("may contain[^.]{0,80}", ignoreCase: true)

  /// "Allergy advice" without a question: what the label and the product data say.
  static func allergenSummary(_ lines: [LabelLine]?, product: OffProduct?) -> String? {
    var parts: [String] = []
    let fromLabel = lines.flatMap { section($0, .allergens) }
    let may = lines.flatMap { lines in mayContain.first(in: lines.map(\.text).joined(separator: " "))?.value }
    if let fromLabel {
      parts.append("Allergy advice on the label: \(LabelsString.trimEnd(fromLabel, "."))."
      )
    } else if let may {
      parts.append("The label says: \(LabelsString.trimEnd(LabelsString.trimmed(may), "."))."
      )
    }
    if let product, !product.allergens.isEmpty { parts.append("Open Food Facts lists \(listWords(product.allergens)).") }
    if let product, !product.traces.isEmpty { parts.append("It may contain traces of \(listWords(product.traces)).") }
    let joined = parts.joined(separator: " ")
    return joined.isEmpty ? nil : joined
  }

  static func listWords(_ words: [String]) -> String {
    switch words.count {
    case 0: ""
    case 1: words[0]
    default: words.dropLast().joined(separator: ", ") + " and " + words[words.count - 1]
    }
  }

  /// The sentence of `text` around `range`, as UTF-16 offsets [start, end).
  private static func sentenceRange(_ text: String, _ range: NSRange) -> Range<Int> {
    let lastIndex = range.location + max(range.length, 1) - 1
    let start = LabelsString.lastIndex(of: ".", in: text, from: range.location).map { $0 + 1 } ?? 0
    let end = LabelsString.index(of: ".", in: text, from: lastIndex).map { $0 + 1 } ?? LabelsString.length(text)
    return start..<max(start, end)
  }

  /// The sentence of `text` that holds `range`, trimmed.
  private static func sentenceAround(_ text: String, _ range: NSRange) -> String {
    let r = sentenceRange(text, range)
    return LabelsString.trimmed(LabelsString.substring(text, from: r.lowerBound, to: r.upperBound))
  }
}
