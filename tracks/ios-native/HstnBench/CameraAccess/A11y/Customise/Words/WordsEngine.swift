/*
 * WordsEngine - "Your words" at the moment speech arrives: the rewrite step before parsing, the
 * macro being built, macros running, and the words grammar (notes/customisation-ios-words.md)
 *
 * VoiceControl.inject calls UtteranceHook.rewrite first, for the phone and the glasses listener
 * alike, before the tools and the app's grammar see anything. In order:
 * 1. A step this engine is injecting itself passes straight through.
 * 2. The words must be for the app (VoiceCommandParser.addressedText: the wake word when needed,
 *    not the app's own speech). Otherwise nothing happens here.
 * 3. A macro still running is cancelled: the user has taken over.
 * 4. A macro being built takes everything: "then read it all", "that's all", "yes", "cancel".
 * 5. One of the user's words: an alias is rewritten to "<address word> <what it means>" and parsed
 *    as usual; a macro starts running.
 * 6. The words and buttons grammars ("when I say ...", "hide light", "call you Robin", "what do my
 *    buttons do"), unless the words are a built-in command.
 * Anything else is left alone.
 */

import Foundation

/// What the rewrite step did with an utterance.
enum UtteranceRewrite: Equatable, Sendable {
  case unchanged
  /// Parse these words instead.
  case rewritten(String)
  /// Used up here (a reply was spoken, or a macro started).
  case handled
}

/// The one hook VoiceControl calls before parsing. Set by MakeItYourOwnWords.install().
@MainActor
enum UtteranceHook {
  static var rewrite: (@MainActor (_ transcript: String, _ context: VoiceContext) -> UtteranceRewrite)?
}

/// A macro being built by voice, between "when I say morning post" and "yes".
struct MacroDraft: Equatable, Sendable {
  var name: String
  var steps: [String] = []
  /// It was read back and a yes or no is due.
  var awaitingConfirmation = false
  var touchedAt: Date

  var macro: WordMacro { WordMacro(name: name, steps: steps) }
}

@MainActor
final class WordsEngine {
  static let shared = WordsEngine(area: .shared, environment: .live)

  struct Environment {
    var say: @MainActor (String) -> Void
    var now: @MainActor () -> Date
    /// The steps a macro runs, as words said to the app.
    var injectStep: @MainActor (String) -> Void
    var isBusy: @MainActor () -> Bool
    var sleep: @MainActor (Double) async -> Void
  }

  /// A draft nobody has spoken to for this long is dropped.
  static let draftTimeout: TimeInterval = 120

  let area: WordsArea
  private let environment: Environment
  private(set) var draft: MacroDraft?
  private(set) lazy var runner = MacroRunner(
    environment: MacroRunner.Environment(
      perform: { [weak self] step in self?.inject(step) }, isBusy: environment.isBusy, sleep: environment.sleep))
  private var injecting = false
  /// Other grammars that hear what this one doesn't claim (the buttons grammar).
  var moreGrammars: [any SettingsGrammar] = []

  init(area: WordsArea, environment: Environment) {
    self.area = area
    self.environment = environment
  }

  // MARK: The hook

  func rewrite(_ transcript: String, context: VoiceContext) -> UtteranceRewrite {
    if injecting { return .unchanged }
    guard let text = VoiceCommandParser.addressedText(transcript, context: context) else { return .unchanged }
    if runner.isRunning { runner.cancel() }
    if let draft, environment.now().timeIntervalSince(draft.touchedAt) > Self.draftTimeout { self.draft = nil }
    if draft != nil {
      speak(continueDraft(text))
      return .handled
    }
    let phrase = WordsText.phrase(text)
    if let alias = area.settings.alias(named: phrase) {
      return .rewritten(AddressWord.prefixed(alias.phrase))
    }
    if let macro = area.settings.macro(named: phrase) {
      runner.run(macro)
      return .handled
    }
    guard WordsUnderstanding.builtInCommand(phrase) == nil else { return .unchanged }
    if let reply = reply(to: text) {
      speak(reply)
      return .handled
    }
    for grammar in moreGrammars {
      guard let reply = grammar.handle(text) else { continue }
      speak(reply)
      return .handled
    }
    return .unchanged
  }

  /// Runs the macro called `name` (a glasses button, a shortcut). False if there is none.
  @discardableResult
  func runMacro(named name: String) -> Bool {
    guard let macro = area.settings.macro(named: WordsText.name(name)) else {
      environment.say(SpokenMessage.wordsNotFound(name))
      return false
    }
    runner.run(macro)
    return true
  }

  private func inject(_ step: String) {
    injecting = true
    defer { injecting = false }
    environment.injectStep(AddressWord.prefixed(step))
  }

  /// An empty reply means "done, nothing to say" (something else is speaking).
  private func speak(_ reply: String) {
    if !reply.isEmpty { environment.say(reply) }
  }

  // MARK: The words grammar

  /// The reply for a words phrase, or nil when the words aren't one.
  func reply(to text: String) -> String? {
    let tokens = WordsText.tokens(text)
    let phrase = tokens.joined(separator: " ")
    guard !tokens.isEmpty else { return nil }

    if let rest = Self.after(["when", "i", "say"], tokens) ?? Self.after(["if", "i", "say"], tokens)
      ?? Self.after(["when", "i", "tell", "you"], tokens)
    {
      return define(rest, raw: text)
    }
    if Self.listPhrases.contains(phrase) {
      let settings = area.settings
      if settings.aliases.isEmpty, settings.macros.isEmpty { return SpokenMessage.wordsNone }
      return SpokenMessage.wordsList(aliases: settings.aliases, macros: settings.macros)
    }
    for lead in Self.forgetLeads {
      if let rest = Self.after(lead, tokens), !["it", "that", "this"].contains(rest.joined(separator: " ")) {
        return area.forget(rest.joined(separator: " "))
      }
    }
    if let rest = Self.after(["what", "does"], tokens), rest.last == "do", rest.count > 1 {
      let name = rest.dropLast().joined(separator: " ")
      if let alias = area.settings.alias(named: name) { return SpokenMessage.wordsMeaning(name, alias.phrase) }
      if let macro = area.settings.macro(named: name) { return SpokenMessage.wordsMeaning(name, macro.spokenSteps) }
      return nil
    }
    if let rest = Self.after(["run"], tokens), area.settings.macro(named: rest.joined(separator: " ")) != nil {
      runMacro(named: rest.joined(separator: " "))
      return ""
    }
    if let reply = menuReply(tokens) { return reply }
    return addressReply(tokens)
  }

  static let listPhrases: Set<String> = [
    "what are my words", "list my words", "my words", "what words do i have", "what are my macros", "list my macros",
    "what have i taught you", "read my words", "tell me my words",
  ]

  static let forgetLeads: [[String]] = [
    ["forget", "the", "word"], ["forget", "my", "word"], ["forget", "my", "macro"], ["forget", "the", "macro"],
    ["delete", "the", "word"], ["delete", "my", "word"], ["delete", "my", "macro"], ["forget"],
  ]

  // MARK: Defining a word or macro

  /// After "when I say": "post open the mail reader", "morning post open mail and read it all",
  /// or just "morning post" (then built step by step).
  private func define(_ rest: [String], raw: String) -> String {
    guard !rest.isEmpty else { return SpokenMessage.wordsNameEmpty }
    if SettingsChanges.isLocked() { return SpokenMessage.customiseLocked }
    // A comma after the name, when the recogniser gives one, says where the name ends. Otherwise
    // the shortest name (up to four words) whose remainder is understood wins.
    let comma = Self.nameLengthBeforeComma(raw).flatMap { (1...rest.count).contains($0) ? $0 : nil }
    for length in comma.map({ [$0] }) ?? Array(1...min(4, rest.count)) {
      let name = rest.prefix(length).joined(separator: " ")
      let tail = Self.trimLead(Array(rest.dropFirst(length)))
      guard !tail.isEmpty, let steps = Self.steps(tail) else { continue }
      if let problem = area.problem(withName: name) { return problem }
      if steps.count == 1 { return area.addAlias(name: name, phrase: steps[0]) }
      let draft = MacroDraft(
        name: name, steps: Array(steps.prefix(WordMacro.maxSteps)), awaitingConfirmation: true, touchedAt: environment.now())
      self.draft = draft
      return SpokenMessage.wordsMacroReadBack(draft.macro)
    }
    // No understood remainder. Where does the name end? At the comma, or before the first word that
    // starts a command ("post open the mailbox"), or it is all name ("morning post").
    let nameLength =
      comma ?? rest.indices.dropFirst().first { WordsUnderstanding.commandLeadWords.contains(rest[$0]) } ?? rest.count
    let tail = Self.trimLead(Array(rest.dropFirst(nameLength)))
    guard tail.isEmpty else { return SpokenMessage.wordsStepNotUnderstood(tail.joined(separator: " ")) }
    let name = rest.prefix(nameLength).joined(separator: " ")
    if let problem = area.problem(withName: name) { return problem }
    draft = MacroDraft(name: name, touchedAt: environment.now())
    return SpokenMessage.wordsMacroStarted(name)
  }

  /// How many words come between "say" and the first comma in the raw transcript, if there is one.
  private static func nameLengthBeforeComma(_ raw: String) -> Int? {
    let lower = raw.lowercased()
    guard let say = lower.range(of: "say ") ?? lower.range(of: "tell you "),
      let comma = lower[say.upperBound...].firstIndex(where: { $0 == "," || $0 == ":" || $0 == ";" })
    else { return nil }
    return VoiceCommandParser.normalize(String(lower[say.upperBound..<comma])).count
  }

  /// Words that join the name to what it does: "I mean", "it should", "to".
  private static let leadIns: [[String]] = [
    ["i", "want", "you", "to"], ["i", "want", "it", "to"], ["i", "mean"], ["it", "means"], ["that", "means"], ["it", "should"],
    ["you", "should"], ["please"], ["to"], ["then"], ["and", "then"], ["and"], ["after", "that"],
  ]

  private static func trimLead(_ tokens: [String]) -> [String] {
    var tokens = tokens
    var changed = true
    while changed {
      changed = false
      for lead in leadIns where tokens.count > lead.count && Array(tokens.prefix(lead.count)) == lead {
        tokens.removeFirst(lead.count)
        changed = true
      }
    }
    return tokens
  }

  /// The commands in "open mail and read it all then light", each one understood, or nil.
  static func steps(_ tokens: [String]) -> [String]? {
    var segments: [[String]] = [[]]
    var index = 0
    while index < tokens.count {
      let token = tokens[index]
      if token == "then" {
        if segments[segments.count - 1].last == "and" { segments[segments.count - 1].removeLast() }
        segments.append([])
      } else if token == "after", index + 1 < tokens.count, tokens[index + 1] == "that" {
        segments.append([])
        index += 1
      } else {
        segments[segments.count - 1].append(token)
      }
      index += 1
    }
    var result: [String] = []
    for segment in segments where !segment.isEmpty {
      guard let parts = splitOnAnd(trimLead(segment)[...]) else { return nil }
      result += parts
    }
    return result.isEmpty ? nil : result
  }

  /// A segment as one command, or commands joined by "and" ("light and colour" stays whole).
  private static func splitOnAnd(_ tokens: ArraySlice<String>) -> [String]? {
    guard !tokens.isEmpty else { return nil }
    let whole = tokens.joined(separator: " ")
    if WordsUnderstanding.understands(whole) { return [whole] }
    for (index, token) in zip(tokens.indices, tokens).reversed() where token == "and" {
      let head = tokens[tokens.startIndex..<index].joined(separator: " ")
      guard WordsUnderstanding.understands(head), let tail = splitOnAnd(tokens[(index + 1)...]) else { continue }
      return [head] + tail
    }
    return nil
  }

  // MARK: Building a macro

  static let cancelPhrases: Set<String> = [
    "cancel", "never mind", "forget it", "stop", "no", "no thanks", "dont save it", "drop it", "nope", "dont",
  ]
  static let confirmPhrases: Set<String> = ["yes", "yes please", "save it", "save", "yeah", "yep", "go ahead", "ok save it"]
  static let finishPhrases: Set<String> = [
    "thats all", "thats it", "that is all", "that is it", "finish", "finished", "done", "im done", "end", "the end",
  ]
  static let readBackPhrases: Set<String> = ["read it back", "what have i got", "what is it so far", "read back"]
  static let removePhrases: Set<String> = [
    "take that out", "scratch that", "remove the last step", "delete the last step", "remove that", "not that",
  ]

  private func continueDraft(_ text: String) -> String {
    guard var draft else { return "" }
    draft.touchedAt = environment.now()
    let phrase = WordsText.phrase(text)
    defer { if self.draft != nil { self.draft = draft } }
    if Self.cancelPhrases.contains(phrase) {
      self.draft = nil
      return SpokenMessage.wordsMacroDropped(draft.name)
    }
    if Self.confirmPhrases.contains(phrase), draft.awaitingConfirmation || !draft.steps.isEmpty {
      if !draft.awaitingConfirmation {
        draft.awaitingConfirmation = true
        return SpokenMessage.wordsMacroReadBack(draft.macro)
      }
      self.draft = nil
      return area.addMacro(draft.macro)
    }
    if Self.finishPhrases.contains(phrase) || Self.readBackPhrases.contains(phrase) || Self.confirmPhrases.contains(phrase) {
      guard !draft.steps.isEmpty else { return SpokenMessage.wordsMacroNeedsAStep }
      draft.awaitingConfirmation = true
      return SpokenMessage.wordsMacroReadBack(draft.macro)
    }
    if Self.removePhrases.contains(phrase) {
      guard !draft.steps.isEmpty else { return SpokenMessage.wordsMacroNeedsAStep }
      draft.steps.removeLast()
      draft.awaitingConfirmation = false
      return SpokenMessage.wordsMacroStepRemoved
    }
    guard let steps = Self.steps(Self.trimLead(WordsText.tokens(text))) else {
      return SpokenMessage.wordsStepNotUnderstood(Self.trimLead(WordsText.tokens(text)).joined(separator: " "))
    }
    guard draft.steps.count + steps.count <= WordMacro.maxSteps else { return SpokenMessage.wordsMacroTooLong }
    draft.steps += steps
    draft.awaitingConfirmation = false
    return SpokenMessage.wordsMacroStepAdded(steps.joined(separator: ", then "))
  }

  // MARK: The tools menu

  private static let positions: [String: Int] = [
    "first": 0, "at the top": 0, "to the top": 0, "top": 0, "second": 1, "third": 2, "fourth": 3, "fifth": 4, "sixth": 5,
    "last": 99, "at the bottom": 99, "to the bottom": 99, "bottom": 99, "at the end": 99, "to the end": 99,
    "number one": 0, "number two": 1, "number three": 2, "number four": 3, "number five": 4, "number six": 5,
  ]
  private static let nudges: [String: Int] = ["up": -1, "higher": -1, "earlier": -1, "down": 1, "lower": 1, "later": 1]

  private func menuReply(_ tokens: [String]) -> String? {
    let phrase = tokens.joined(separator: " ")
    if ["show all tools", "show all", "show every tool", "show everything", "show hidden tools", "show all my tools",
      "unhide everything", "unhide all tools", "bring back all tools"].contains(phrase)
    {
      return area.showAll()
    }
    if let rest = Self.after(["put"], tokens) ?? Self.after(["move"], tokens) {
      return moveReply(rest)
    }
    if let rest = Self.after(["hide"], tokens) ?? Self.after(["take"], tokens).flatMap(Self.droppingOffMenu) {
      guard let tools = ToolID.namedList(rest.joined(separator: " ")) else {
        return SpokenMessage.homeUnknownTool(rest.joined(separator: " "))
      }
      return area.hide(tools)
    }
    if let rest = Self.after(["show"], tokens) ?? Self.after(["unhide"], tokens),
      let tools = ToolID.namedList(rest.joined(separator: " "))
    {
      return area.show(tools)
    }
    return nil
  }

  /// "light off the menu" -> "light".
  private static func droppingOffMenu(_ tokens: [String]) -> [String]? {
    for tail in [["off", "the", "menu"], ["off", "my", "menu"], ["off", "the", "list"]] where tokens.count > 3 {
      if Array(tokens.suffix(3)) == tail { return Array(tokens.dropLast(3)) }
    }
    return nil
  }

  /// "labels first", "labels to the top", "mail up", "light second". nil unless it names a tool,
  /// so "put it back" stays the settings core's.
  private func moveReply(_ rest: [String]) -> String? {
    for length in stride(from: min(3, rest.count - 1), through: 1, by: -1) {
      let where_ = rest.suffix(length).joined(separator: " ")
      let name = rest.dropLast(length).joined(separator: " ")
      guard let tool = ToolID.named(name) else { continue }
      if let position = Self.positions[where_] { return area.move(tool, to: position) }
      if let step = Self.nudges[where_] { return area.move(tool, by: step) }
    }
    return nil
  }

  // MARK: The address word

  private static let renameLeads: [[String]] = [
    ["call", "you"], ["call", "yourself"], ["ill", "call", "you"], ["i", "will", "call", "you"], ["your", "name", "is"],
    ["your", "new", "name", "is"], ["change", "your", "name", "to"], ["set", "your", "name", "to"], ["answer", "to"],
    ["respond", "to"],
  ]
  private static let askNamePhrases: Set<String> = [
    "whats your name", "what is your name", "what do i call you", "what are you called", "what should i call you",
  ]

  private func addressReply(_ tokens: [String]) -> String? {
    if Self.askNamePhrases.contains(tokens.joined(separator: " ")) { return SpokenMessage.addressWordIs(area.addressWord) }
    for lead in Self.renameLeads {
      guard var rest = Self.after(lead, tokens) else { continue }
      if rest.last == "again" { rest.removeLast() }
      if rest.last == "instead" { rest.removeLast() }
      guard !rest.isEmpty else { return SpokenMessage.addressWordTooShort }
      return area.setAddressWord(rest.joined(separator: " "))
    }
    return nil
  }

  // MARK: Helpers

  /// The words after `lead`, or nil if `tokens` doesn't start with it or nothing follows.
  static func after(_ lead: [String], _ tokens: [String]) -> [String]? {
    guard tokens.count > lead.count, Array(tokens.prefix(lead.count)) == lead else { return nil }
    return Array(tokens.dropFirst(lead.count))
  }
}

/// The words grammar for SettingsVoice (the settings core routes to it too).
struct WordsGrammar: SettingsGrammar {
  let engine: WordsEngine
  func handle(_ utterance: String) -> String? { engine.reply(to: utterance) }
}

extension WordsEngine.Environment {
  static let live = WordsEngine.Environment(
    say: { Announcer.shared.say($0, kind: .reply) },
    now: { Date() },
    injectStep: { VoiceControl.shared.inject(transcript: $0) },
    isBusy: { Announcer.shared.isSpeaking || TextReader.shared.isActive },
    sleep: { seconds in try? await Task.sleep(for: .seconds(seconds)) }
  )
}
