/*
 * WordsModel - what "Your words" stores: the user's own words (aliases), macros, the tools menu
 * order, hidden tools and the address word (notes/customisation-ios-words.md)
 *
 * Plain values, JSON for SettingsArea snapshots. Decoding keeps the default for any field that is
 * missing or unreadable, so an old snapshot or a profile from a newer build still loads.
 */

import Foundation

/// "When I say post, open the mail reader": `name` stands for `phrase`.
struct WordAlias: Codable, Equatable, Hashable, Sendable {
  /// As the parser compares it: lower case, no punctuation ("post").
  var name: String
  /// What it stands for, as it was said ("open the mail reader"). Always something the app's own
  /// grammar or a tool's grammar understands (WordsUnderstanding).
  var phrase: String
}

/// "When I say morning post, open mail and read it all": `name` runs `steps` in order.
struct WordMacro: Codable, Equatable, Hashable, Sendable {
  var name: String
  var steps: [String]

  static let maxSteps = 10

  /// "open mail, then read it all".
  var spokenSteps: String { steps.joined(separator: ", then ") }
}

struct WordsSettings: Codable, Equatable, Sendable {
  var aliases: [WordAlias] = []
  var macros: [WordMacro] = []
  /// Every tool once, in the order the tools home and "list tools" give them (ToolID raw values).
  var homeOrder: [String] = ToolID.allCases.map(\.rawValue)
  /// Tools left off the tools home and "list tools". Voice can still open them by name.
  var hiddenTools: [String] = []
  var addressWord: String = AddressWord.defaultWord

  init() {}

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    aliases = (try? container.decodeIfPresent([WordAlias].self, forKey: .aliases)) ?? []
    macros = (try? container.decodeIfPresent([WordMacro].self, forKey: .macros)) ?? []
    homeOrder = Self.completeOrder((try? container.decodeIfPresent([String].self, forKey: .homeOrder)) ?? [])
    let hidden = (try? container.decodeIfPresent([String].self, forKey: .hiddenTools)) ?? []
    hiddenTools = hidden.filter { ToolID(rawValue: $0) != nil }
    let word = (try? container.decodeIfPresent(String.self, forKey: .addressWord)) ?? AddressWord.defaultWord
    addressWord = word.isEmpty ? AddressWord.defaultWord : word
  }

  /// Known tools only, each once, with any tool the stored order doesn't know (a newer tool) at the end.
  static func completeOrder(_ stored: [String]) -> [String] {
    var seen = Set<String>()
    var order = stored.filter { ToolID(rawValue: $0) != nil && seen.insert($0).inserted }
    order += ToolID.allCases.map(\.rawValue).filter { !seen.contains($0) }
    return order
  }

  var orderedTools: [ToolID] { homeOrder.compactMap(ToolID.init(rawValue:)) }
  var visibleTools: [ToolID] { orderedTools.filter { !hiddenTools.contains($0.rawValue) } }

  func alias(named name: String) -> WordAlias? { aliases.first { $0.name == name } }
  func macro(named name: String) -> WordMacro? { macros.first { $0.name == name } }
}

// MARK: - Tool names

extension ToolID {
  /// What people call it in "put labels first", "hide light and colour", "my favourite is mail".
  var spokenNames: [String] {
    switch self {
    case .read: ["read text", "reading", "reader", "read", "text reader", "the reader"]
    case .mail: ["mail reader", "mail", "the mail reader", "letters", "mail tool"]
    case .labels: ["labels and barcodes", "labels", "label", "barcodes", "barcode", "the labels", "label reader"]
    case .watch: ["watch for text", "watch", "watching", "text watcher"]
    case .ask: ["ask about the text", "ask", "questions", "ask a question"]
    case .light: ["light and colour", "light and color", "light", "colour", "color", "colours", "colors", "the light"]
    }
  }

  /// The tool these words name ("labels", "the mail reader"), or nil.
  static func named(_ words: String) -> ToolID? {
    var phrase = WordsText.phrase(words)
    if phrase.hasPrefix("the ") { phrase.removeFirst(4) }
    if phrase.hasSuffix(" tool") { phrase.removeLast(5) }
    if phrase.hasPrefix("open ") { phrase.removeFirst(5) }
    return ToolID.allCases.first { tool in tool.spokenNames.contains(phrase) || tool.title.lowercased() == phrase }
  }

  /// One or more tools: "light and colour", "labels and ask", "mail, labels and light".
  static func namedList(_ words: String) -> [ToolID]? {
    let tokens = WordsText.tokens(words.replacingOccurrences(of: ",", with: " and "))
    return split(tokens[...])
  }

  /// The tokens as a list of tool names, with or without "and" between them (the recogniser's
  /// commas are gone by now), or nil. Whole names win, so "light and colour" is one tool, not two.
  private static func split(_ tokens: ArraySlice<String>) -> [ToolID]? {
    guard !tokens.isEmpty else { return nil }
    if let tool = named(tokens.joined(separator: " ")) { return [tool] }
    for end in tokens.indices.dropFirst() {
      guard let head = named(tokens[tokens.startIndex..<end].joined(separator: " ")) else { continue }
      var rest = tokens[end...]
      if rest.first == "and" { rest = rest.dropFirst() }
      if let tail = split(rest) { return [head] + tail }
    }
    return nil
  }
}
