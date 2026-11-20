/*
 * WordsArea - "Your words" as a SettingsArea: the user's own words, macros, the tools menu and
 * the address word (notes/customisation-ios-words.md)
 *
 * Every user-made change goes through change(_:description:apply:), which refuses while settings
 * are locked, records the snapshot from before for "undo", applies, saves and speaks nothing
 * itself: each method returns the line to say, so voice and the screen say the same thing.
 * Stored as one JSON value in UserDefaults ("customise.words.v1"). The address word and the menu
 * order are mirrored where code off the main actor reads them (AddressWord, SpokenMessage.toolsList).
 */

import Foundation
import Observation

@MainActor
@Observable
final class WordsArea: SettingsArea {
  static let shared = WordsArea(defaults: .standard, mirrorsAddressWord: true)

  static let areaID = "words"
  static let storageKey = "customise.words.v1"

  var spokenName: String { "your words" }

  private(set) var settings: WordsSettings

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let mirrorsAddressWord: Bool
  /// Read off the main actor by SpokenMessage.toolsList.
  nonisolated static var visibleToolsMirror: [ToolID] { menuMirror.withLock { $0 } }
  private nonisolated static let menuMirror = LockedValue(ToolID.allCases)

  /// `mirrorsAddressWord`: only the app's own instance sets the parser's address word and the menu
  /// mirror; test instances leave them alone unless they ask.
  init(defaults: UserDefaults, mirrorsAddressWord: Bool) {
    self.defaults = defaults
    self.mirrorsAddressWord = mirrorsAddressWord
    if let data = defaults.data(forKey: Self.storageKey), let stored = try? JSONDecoder().decode(WordsSettings.self, from: data) {
      settings = stored
    } else {
      settings = WordsSettings()
    }
    publish()
  }

  var visibleTools: [ToolID] { settings.visibleTools }
  var orderedTools: [ToolID] { settings.orderedTools }
  var aliases: [WordAlias] { settings.aliases }
  var macros: [WordMacro] { settings.macros }
  var addressWord: String { settings.addressWord }

  func isHidden(_ tool: ToolID) -> Bool { settings.hiddenTools.contains(tool.rawValue) }

  // MARK: SettingsArea

  func snapshot() -> Data {
    (try? WordsText.encoder.encode(settings)) ?? Data()
  }

  func restore(_ data: Data) throws {
    settings = try JSONDecoder().decode(WordsSettings.self, from: data)
    save()
  }

  func resetToDefaults() {
    settings = WordsSettings()
    save()
  }

  func differencesFromDefaults() -> [String] {
    let defaults = WordsSettings()
    var lines: [String] = []
    for alias in settings.aliases { lines.append("\(alias.name) means \(alias.phrase)") }
    for macro in settings.macros { lines.append("\(macro.name) will \(macro.spokenSteps)") }
    if settings.homeOrder != defaults.homeOrder {
      lines.append("tools menu order: \(WordsText.list(settings.orderedTools.map { $0.title.lowercased() }))")
    }
    let hidden = settings.orderedTools.filter(isHidden)
    if !hidden.isEmpty { lines.append("hidden tools: \(WordsText.list(hidden.map { $0.title.lowercased() }))") }
    if settings.addressWord != defaults.addressWord { lines.append("you call me \(settings.addressWord)") }
    return lines
  }

  // MARK: Changes

  /// Refuses while locked; otherwise records the before snapshot, applies `apply` and saves.
  /// `apply` returns the line to say, or a refusal with `changed` false (nothing recorded).
  private func change(_ description: String, _ apply: (inout WordsSettings) -> (line: String, changed: Bool)) -> String {
    if SettingsChanges.isLocked() { return SpokenMessage.customiseLocked }
    var next = settings
    let result = apply(&next)
    guard result.changed, next != settings else { return result.line }
    SettingsChanges.record(Self.areaID, before: snapshot(), description: description)
    settings = next
    save()
    return result.line
  }

  /// Why `name` can't be a new word right now, or nil.
  func problem(withName rawName: String) -> String? {
    if SettingsChanges.isLocked() { return SpokenMessage.customiseLocked }
    return WordsUnderstanding.problem(withName: WordsText.name(rawName), in: settings)
  }

  /// "When I say post, open the mail reader."
  func addAlias(name rawName: String, phrase rawPhrase: String) -> String {
    let name = WordsText.name(rawName)
    let phrase = WordsText.phrase(rawPhrase)
    if let problem = problem(withName: name) { return problem }
    guard WordsUnderstanding.understands(phrase) else { return SpokenMessage.wordsStepNotUnderstood(phrase) }
    return change("your word \(name)") { settings in
      settings.aliases.append(WordAlias(name: name, phrase: phrase))
      return (SpokenMessage.wordsAliasSaved(name, phrase), true)
    }
  }

  /// A macro that has been read back and confirmed.
  func addMacro(_ macro: WordMacro) -> String {
    let name = WordsText.name(macro.name)
    if let problem = problem(withName: name) { return problem }
    let steps = macro.steps.map(WordsText.phrase)
    guard !steps.isEmpty else { return SpokenMessage.wordsMacroNeedsAStep }
    if let bad = steps.first(where: { !WordsUnderstanding.understands($0) }) { return SpokenMessage.wordsStepNotUnderstood(bad) }
    let saved = WordMacro(name: name, steps: Array(steps.prefix(WordMacro.maxSteps)))
    return change("your macro \(name)") { settings in
      settings.macros.append(saved)
      return (SpokenMessage.wordsMacroSaved(saved), true)
    }
  }

  /// "Forget post": an alias or a macro.
  func forget(_ rawName: String) -> String {
    let name = WordsText.name(rawName)
    guard settings.alias(named: name) != nil || settings.macro(named: name) != nil else {
      return SpokenMessage.wordsNotFound(name)
    }
    return change("forgot \(name)") { settings in
      settings.aliases.removeAll { $0.name == name }
      settings.macros.removeAll { $0.name == name }
      return (SpokenMessage.wordsForgotten(name), true)
    }
  }

  // MARK: Tools menu

  /// Moves `tool` to `position` (0 is first) in the menu order.
  func move(_ tool: ToolID, to position: Int) -> String {
    change("tools menu, \(tool.title.lowercased())") { settings in
      var order = settings.homeOrder
      guard let from = order.firstIndex(of: tool.rawValue) else { return (SpokenMessage.homeAlreadyThere(tool), false) }
      let target = max(0, min(position, order.count - 1))
      guard from != target else { return (SpokenMessage.homeAlreadyThere(tool), false) }
      order.remove(at: from)
      order.insert(tool.rawValue, at: target)
      settings.homeOrder = order
      // Moving a hidden tool means wanting it: show it too.
      settings.hiddenTools.removeAll { $0 == tool.rawValue }
      return (SpokenMessage.homeMoved(tool, position: target, count: order.count), true)
    }
  }

  /// Moves `tool` one place up (negative) or down (positive).
  func move(_ tool: ToolID, by offset: Int) -> String {
    guard let from = settings.homeOrder.firstIndex(of: tool.rawValue) else { return SpokenMessage.homeAlreadyThere(tool) }
    return move(tool, to: from + offset)
  }

  func hide(_ tools: [ToolID]) -> String {
    change("hid \(WordsText.list(tools.map { $0.title.lowercased() }))") { settings in
      let hidden = Set(settings.hiddenTools).union(tools.map(\.rawValue))
      guard hidden.count < ToolID.allCases.count else { return (SpokenMessage.homeCantHideAll, false) }
      settings.hiddenTools = settings.homeOrder.filter(hidden.contains)
      return (SpokenMessage.homeHidden(tools), true)
    }
  }

  func show(_ tools: [ToolID]) -> String {
    change("showed \(WordsText.list(tools.map { $0.title.lowercased() }))") { settings in
      settings.hiddenTools.removeAll { raw in tools.contains { $0.rawValue == raw } }
      return (SpokenMessage.homeShown(tools), true)
    }
  }

  func showAll() -> String {
    guard !settings.hiddenTools.isEmpty else { return SpokenMessage.homeNothingHidden }
    return change("showed all tools") { settings in
      settings.hiddenTools = []
      return (SpokenMessage.homeAllShown, true)
    }
  }

  // MARK: Address word

  func setAddressWord(_ rawWord: String) -> String {
    if SettingsChanges.isLocked() { return SpokenMessage.customiseLocked }
    let word = AddressWord.normalized(rawWord)
    if word == settings.addressWord { return SpokenMessage.addressWordSame(word) }
    if let problem = WordsUnderstanding.problem(withAddressWord: word, in: settings) { return problem }
    return change("address word \(word)") { settings in
      settings.addressWord = word
      return (SpokenMessage.addressWordSet(word), true)
    }
  }

  // MARK: Storage

  private func save() {
    if let data = try? WordsText.encoder.encode(settings) { defaults.set(data, forKey: Self.storageKey) }
    publish()
  }

  /// Keeps the off-main-actor copies in step.
  private func publish() {
    guard mirrorsAddressWord else { return }
    AddressWord.current = settings.addressWord
    let visible = settings.visibleTools
    Self.menuMirror.withLock { $0 = visible }
  }
}

/// A value behind a lock, for the few settings read off the main actor.
final class LockedValue<Value: Sendable>: @unchecked Sendable {
  private var value: Value
  private let lock = NSLock()

  init(_ value: Value) { self.value = value }

  func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
    lock.lock()
    defer { lock.unlock() }
    return body(&value)
  }
}
