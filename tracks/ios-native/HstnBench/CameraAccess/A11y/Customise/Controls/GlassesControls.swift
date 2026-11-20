/*
 * GlassesControls - a glasses event arrives (DATGlassesInputs, or a test) and the mapped
 * SpeakUp action runs; plus the buttons grammar ("what do my buttons do", "make double tap repeat")
 *
 * Capture short and double press: DAT 1.0 reports a double press as a short press followed by a
 * double press (known issue, docs/develop/dat/knownissues). So while a double press is mapped to
 * something, a short press waits `doublePressWindow` and is dropped if the double press follows.
 * With the double press free, a short press acts at once.
 *
 * Actions run through VoiceControl.perform, the same calls as speech, Magic Tap and Siri.
 */

import Foundation

@MainActor
final class GlassesControls {
  static let shared = GlassesControls(area: .shared, environment: .live)

  struct Environment {
    var perform: @MainActor (VoiceCommand) -> Void
    var openTool: @MainActor () -> ToolID?
    var runMacro: @MainActor (String) -> Void
    var say: @MainActor (String) -> Void
    var sleep: @MainActor (Double) async -> Void
  }

  /// How long a short press waits for a double press.
  static let doublePressWindow: Double = 0.45

  let area: ControlsArea
  private let environment: Environment
  private var pendingShort: Task<Void, Never>?
  /// Actions run, newest last. For tests and the log.
  private(set) var history: [ControlAction] = []

  init(area: ControlsArea, environment: Environment) {
    self.area = area
    self.environment = environment
  }

  /// A glasses event. Ignored while glasses buttons are off.
  func receive(_ control: GlassesControl) {
    guard area.enabled else { return }
    switch control {
    case .captureShort where area.action(for: .captureDouble) != .nothing:
      pendingShort?.cancel()
      let sleep = environment.sleep
      pendingShort = Task { [weak self] in
        await sleep(Self.doublePressWindow)
        guard !Task.isCancelled, let self else { return }
        self.pendingShort = nil
        self.perform(self.area.action(for: .captureShort))
      }
    case .captureDouble:
      pendingShort?.cancel()
      pendingShort = nil
      perform(area.action(for: control))
    default:
      perform(area.action(for: control))
    }
  }

  /// Waits for a short press that is still waiting for a double press. For tests.
  func settle() async { await pendingShort?.value }

  func perform(_ action: ControlAction) {
    guard action != .nothing else { return }
    history.append(action)
    switch action {
    case .nothing: break
    case .look:
      // The open tool looks again (its first line and a new look); otherwise Read text reads.
      if let open = environment.openTool(), open != .read {
        environment.perform(VoiceCommand.open(open))
      } else {
        environment.perform(.read)
      }
    case .read: environment.perform(.read)
    case .repeatLast: environment.perform(.repeatLast)
    case .stop: environment.perform(.stop)
    case .next: environment.perform(.continueOn)
    case .previous: environment.perform(.back)
    case .status: environment.perform(.status)
    case .help: environment.perform(.help)
    case .favouriteTool:
      guard let tool = area.favouriteTool else {
        environment.say(SpokenMessage.favouriteNone)
        return
      }
      environment.perform(VoiceCommand.open(tool))
    case .tool(let tool): environment.perform(VoiceCommand.open(tool))
    case .macro(let name): environment.runMacro(name)
    }
  }
}

extension GlassesControls.Environment {
  static let live = GlassesControls.Environment(
    perform: { VoiceControl.shared.perform($0) },
    openTool: { (VoiceControl.shared.tools as? ToolHub)?.openTool },
    runMacro: { WordsEngine.shared.runMacro(named: $0) },
    say: { Announcer.shared.say($0, kind: .reply) },
    sleep: { seconds in try? await Task.sleep(for: .seconds(seconds)) }
  )
}

// MARK: - Grammar

/// "What do my buttons do", "when I double tap, repeat", "make hold read", "glasses buttons off",
/// "make mail my favourite", "open my favourite". Shared by both builds; the App Store build says
/// glasses buttons need the Beta, but the favourite tool works everywhere.
struct ControlsGrammar: SettingsGrammar {
  let area: ControlsArea
  var macroNames: @MainActor () -> [String] = { WordsArea.shared.macros.map(\.name) }
  var openFavourite: @MainActor (ToolID) -> Void = { VoiceControl.shared.perform(VoiceCommand.open($0)) }
  var glassesSupported = GlassesSupport.isBuiltIn

  static let readBackPhrases: Set<String> = [
    "what do my buttons do", "what do the buttons do", "what do my glasses buttons do", "what are my buttons",
    "read my buttons", "list my buttons", "what does my button do", "what do my controls do",
  ]

  func handle(_ utterance: String) -> String? {
    let tokens = WordsText.tokens(utterance)
    let phrase = tokens.joined(separator: " ")
    guard !tokens.isEmpty else { return nil }
    if Self.readBackPhrases.contains(phrase) { return area.readBack(glassesSupported: glassesSupported) }
    if let reply = favouriteReply(tokens) { return reply }
    if let on = Self.switchPhrase(phrase) {
      return glassesSupported ? area.setEnabled(on) : SpokenMessage.controlsNeedGlassesBuild
    }
    if case let (control, rest)? = Self.mapping(tokens) {
      guard glassesSupported else { return SpokenMessage.controlsNeedGlassesBuild }
      guard let action = ControlAction.named(rest, macros: macroNames()) else {
        return SpokenMessage.controlsUnknownAction(rest.joined(separator: " "))
      }
      return area.set(control, to: action)
    }
    if let rest = WordsEngine.after(["what", "does"], tokens), rest.last == "do",
      case let (control, used)? = GlassesControl.named(atStartOf: Array(rest.dropLast())), used == rest.count - 1
    {
      guard glassesSupported else { return SpokenMessage.controlsNeedGlassesBuild }
      return SpokenMessage.controlsSet(control, area.action(for: control)).replacingOccurrences(of: " now.", with: ".")
    }
    return nil
  }

  private static func switchPhrase(_ phrase: String) -> Bool? {
    switch phrase {
    case "glasses buttons on", "buttons on", "turn on the glasses buttons", "turn the glasses buttons on",
      "turn on glasses buttons", "use the glasses buttons":
      true
    case "glasses buttons off", "buttons off", "turn off the glasses buttons", "turn the glasses buttons off",
      "turn off glasses buttons", "stop using the glasses buttons":
      false
    default: nil
    }
  }

  /// "when I double tap, repeat", "make double tap repeat", "set hold to read", "double tap should repeat".
  private static func mapping(_ tokens: [String]) -> (GlassesControl, [String])? {
    for lead in [["when", "i"], ["if", "i"], ["make"], ["set"], ["change"], ["make", "a"], ["set", "the"], []] {
      guard tokens.count > lead.count, Array(tokens.prefix(lead.count)) == lead else { continue }
      let rest = Array(tokens.dropFirst(lead.count))
      guard case let (control, used)? = GlassesControl.named(atStartOf: rest), rest.count > used else { continue }
      // A bare "<control> ..." only counts with a joining word, so "hold on" stays nobody's.
      let after = Array(rest.dropFirst(used))
      if lead.isEmpty, !["should", "will", "to"].contains(after[0]) { continue }
      return (control, after)
    }
    return nil
  }

  private func favouriteReply(_ tokens: [String]) -> String? {
    let phrase = tokens.joined(separator: " ").replacingOccurrences(of: "favorite", with: "favourite")
    if ["whats my favourite", "whats my favourite tool", "what is my favourite tool", "which is my favourite tool"].contains(phrase) {
      return area.favouriteTool.map(SpokenMessage.favouriteIs) ?? SpokenMessage.favouriteNone
    }
    if ["open my favourite", "open my favourite tool", "my favourite tool", "favourite tool", "open favourite tool"].contains(phrase) {
      guard let tool = area.favouriteTool else { return SpokenMessage.favouriteNone }
      openFavourite(tool)
      return ""
    }
    let words = phrase.split(separator: " ").map(String.init)
    // "make mail my favourite (tool)", "my favourite (tool) is mail", "set my favourite (tool) to mail".
    for suffix in [["my", "favourite", "tool"], ["my", "favourite"]] where words.count > suffix.count + 1 {
      guard words[0] == "make", Array(words.suffix(suffix.count)) == suffix else { continue }
      let name = words.dropFirst().dropLast(suffix.count).joined(separator: " ")
      guard let tool = ToolID.named(name) else { return SpokenMessage.homeUnknownTool(name) }
      return area.setFavourite(tool)
    }
    for lead in [["my", "favourite", "tool", "is"], ["my", "favourite", "is"], ["set", "my", "favourite", "tool", "to"],
      ["set", "my", "favourite", "to"], ["favourite", "tool"]]
    where words.count > lead.count && Array(words.prefix(lead.count)) == lead {
      let name = words.dropFirst(lead.count).joined(separator: " ")
      if ["nothing", "none"].contains(name) { return area.setFavourite(nil) }
      guard let tool = ToolID.named(name) else { return SpokenMessage.homeUnknownTool(name) }
      return area.setFavourite(tool)
    }
    return nil
  }
}
