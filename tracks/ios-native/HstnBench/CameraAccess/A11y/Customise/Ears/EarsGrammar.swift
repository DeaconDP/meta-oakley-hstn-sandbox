/*
 * EarsGrammar - Your ears by voice
 *
 * Fixed phrases ("move it left a bit", "centre the sound", "I use mono", "clear speech on",
 * "check clear speech", "someone's talking to me") plus one small pattern for ear routing:
 *
 *   [put|send|play] <kinds> in|to|into|through [my|the] left|right|both [ear|ears|side]
 *   kinds: speech/voice, sounds/earcons/beeps, alerts/warnings, everything; joined with "and"
 *
 * Two groups only count in a state: the listening check's answers ("A", "B", "same", "again",
 * "cancel") while it runs, and "carry on" while conversation mode is on. "carry on" is also
 * VoiceCommand's continue, so the settings router has to try this grammar first for it to end
 * conversation mode; "conversation over" and "I'm done talking" work either way.
 */

import Foundation

@MainActor
struct EarsGrammar: SettingsGrammar {
  enum Action: Hashable, Sendable {
    case balanceLeft
    case balanceRight
    case centre
    case monoOn
    case monoOff
    case clearSpeechOn
    case clearSpeechOff
    case checkClearSpeech
    case conversationOn
    case conversationOff
    case route([SoundKind], EarRoute)
  }

  enum CheckAnswer: Sendable {
    case choose(ClarityLadder.Choice)
    case again
    case cancel
  }

  nonisolated static let phrases: [Action: [String]] = [
    .balanceLeft: [
      "move it left a bit", "move it left", "move it to the left", "move the sound left", "move the sound left a bit",
      "move the sound to the left", "sound left a bit", "left a bit", "a bit more left", "a bit to the left",
      "more to the left", "balance left", "more left",
    ],
    .balanceRight: [
      "move it right a bit", "move it right", "move it to the right", "move the sound right", "move the sound right a bit",
      "move the sound to the right", "sound right a bit", "right a bit", "a bit more right", "a bit to the right",
      "more to the right", "balance right", "more right",
    ],
    .centre: [
      "centre the sound", "center the sound", "centre it", "center it", "sound in the middle", "sound in the centre",
      "sound in the center", "balance centre", "balance center", "centre the balance", "center the balance",
      "balance in the middle",
    ],
    .monoOn: [
      "i use mono", "i use mono audio", "im using mono", "i am using mono", "mono on", "mono audio on", "turn on mono",
      "turn mono on", "use mono",
    ],
    .monoOff: [
      "mono off", "mono audio off", "turn off mono", "turn mono off", "i dont use mono", "stereo", "use stereo", "stereo on",
    ],
    .clearSpeechOn: [
      "clear speech", "clear speech on", "clearer speech", "speak clearly", "speak more clearly", "make it clearer",
      "turn on clear speech", "turn clear speech on", "clearer voice",
    ],
    .clearSpeechOff: [
      "clear speech off", "turn off clear speech", "turn clear speech off", "normal speech", "normal voice",
    ],
    .checkClearSpeech: [
      "check clear speech", "tune clear speech", "clear speech check", "clarity check", "test clear speech",
      "which is clearer",
    ],
    .conversationOn: [
      "someones talking to me", "someone is talking to me", "somebodys talking to me", "somebody is talking to me",
      "someones speaking to me", "im talking to someone", "i am talking to someone", "im in a conversation",
      "conversation mode", "conversation mode on",
    ],
    .conversationOff: [
      "conversation over", "conversation mode off", "end conversation mode", "stop conversation mode", "im done talking",
      "you can talk again", "talk again",
    ],
  ]

  /// Ends conversation mode, but only while it's on.
  nonisolated static let conversationEndWhileOn: Set<String> = ["carry on", "continue", "go on", "im done", "im back"]

  nonisolated static let checkAnswers: [String: CheckAnswer] = {
    var answers: [String: CheckAnswer] = [:]
    for phrase in ["a", "option a", "first", "the first", "first one", "the first one", "ay", "eh"] {
      answers[phrase] = .choose(.a)
    }
    for phrase in ["b", "option b", "second", "the second", "second one", "the second one", "be", "bee"] {
      answers[phrase] = .choose(.b)
    }
    for phrase in ["same", "the same", "about the same", "no difference", "theyre the same", "both the same", "i cant tell"] {
      answers[phrase] = .choose(.same)
    }
    for phrase in ["again", "play them again", "say them again", "repeat", "repeat that"] { answers[phrase] = .again }
    for phrase in ["cancel", "cancel the check", "stop the check", "end the check", "never mind", "stop"] {
      answers[phrase] = .cancel
    }
    return answers
  }()

  nonisolated static let lookup: [String: Action] = {
    var lookup: [String: Action] = [:]
    for (action, list) in phrases {
      for phrase in list { lookup[phrase] = action }
    }
    return lookup
  }()

  nonisolated static var allPhrases: [String] { phrases.values.flatMap { $0 } }

  let area: EarsArea

  init(area: EarsArea = .shared) {
    self.area = area
  }

  nonisolated static func action(for utterance: String) -> Action? {
    let words = AudioPhrases.words(utterance)
    return lookup[words] ?? route(words)
  }

  func handle(_ utterance: String) -> String? {
    let words = AudioPhrases.words(utterance)
    if ClarityCheck.shared.isRunning, let answer = Self.checkAnswers[words] {
      switch answer {
      case .choose(let choice): return ClarityCheck.shared.answer(choice)
      case .again: return ClarityCheck.shared.playAgain()
      case .cancel: return ClarityCheck.shared.cancel()
      }
    }
    if ConversationMode.shared.isActive, Self.conversationEndWhileOn.contains(words) {
      return ConversationMode.shared.end()
    }
    guard let action = Self.action(for: utterance) else { return nil }
    switch action {
    case .balanceLeft: return area.moveBalance(steps: -1)
    case .balanceRight: return area.moveBalance(steps: 1)
    case .centre: return area.centreBalance()
    case .monoOn: return area.setUserMono(true)
    case .monoOff: return area.setUserMono(false)
    case .clearSpeechOn: return area.setClearSpeech(true)
    case .clearSpeechOff: return area.setClearSpeech(false)
    case .checkClearSpeech: return ClarityCheck.shared.start()
    case .conversationOn: return ConversationMode.shared.start()
    case .conversationOff: return ConversationMode.shared.end()
    case .route(let kinds, let route): return area.setRoute(route, for: kinds)
    }
  }

  // MARK: Ear routing pattern

  nonisolated private static let kindWords: [String: [SoundKind]] = [
    "speech": [.speech], "voice": [.speech], "your voice": [.speech], "the voice": [.speech], "talking": [.speech],
    "sounds": [.earcon], "the sounds": [.earcon], "earcons": [.earcon], "the earcons": [.earcon], "ear cons": [.earcon],
    "beeps": [.earcon], "the beeps": [.earcon],
    "alerts": [.alert], "the alerts": [.alert], "warnings": [.alert], "the warnings": [.alert],
    "everything": [], "all sounds": [], "all": [],
  ]
  nonisolated private static let leadVerbs: Set<String> = ["put", "send", "play", "move"]
  nonisolated private static let prepositions: Set<String> = ["in", "to", "into", "through", "on"]
  nonisolated private static let sideWords: [String: EarRoute] = ["left": .left, "right": .right, "both": .both]
  nonisolated private static let tailWords: Set<String> = ["ear", "ears", "side", "only"]

  /// "speech in my left ear" -> ([.speech], .left). `[]` means every kind.
  nonisolated static func route(_ words: String) -> Action? {
    var tokens = words.split(separator: " ").map(String.init)
    if let first = tokens.first, leadVerbs.contains(first) { tokens.removeFirst() }
    guard let prepositionIndex = tokens.firstIndex(where: { prepositions.contains($0) }), prepositionIndex > 0 else {
      return nil
    }
    let kindPart = tokens[..<prepositionIndex].joined(separator: " ")
    var kinds: [SoundKind] = []
    var everything = false
    for piece in kindPart.components(separatedBy: " and ") {
      guard let mapped = kindWords[piece.trimmingCharacters(in: .whitespaces)] else { return nil }
      if mapped.isEmpty { everything = true }
      kinds += mapped.filter { !kinds.contains($0) }
    }
    var rest = Array(tokens[(prepositionIndex + 1)...])
    if let first = rest.first, first == "my" || first == "the" { rest.removeFirst() }
    guard let sideWord = rest.first, let side = sideWords[sideWord] else { return nil }
    rest.removeFirst()
    guard rest.allSatisfy({ tailWords.contains($0) }) else { return nil }
    // "in my left" alone is too loose: need an ear/side word unless it's "both".
    guard !rest.isEmpty || side == .both else { return nil }
    return .route(everything ? [] : kinds, side)
  }
}
