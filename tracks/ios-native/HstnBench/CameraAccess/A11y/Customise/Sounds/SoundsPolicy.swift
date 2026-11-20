/*
 * SoundsPolicy - what the Announcer does with a line, given the Sounds settings and conversation mode
 *
 * Pure (plan(...)), so the rules are unit-tested; Announcer.play asks it once per line:
 *
 * 1. Conversation mode: nothing is spoken except the conversation mode lines themselves. A line
 *    with an earcon plays just the earcon (if earcons are on); anything else is held back and noted,
 *    so "carry on" can say "say repeat to hear what you missed".
 * 2. Earcons only: a status line with an earcon plays just the earcon. Replies are spoken.
 * 3. Say it instead of beeping: the earcon's meaning is spoken before the line, and no tone.
 * 4. Otherwise the earcon (if earcons are on), then the line, as before.
 */

import Foundation

enum LinePlan: Equatable, Sendable {
  /// Play `earcon` (if any), then speak the text with `prefix` in front (if any).
  case speak(earcon: Earcon?, prefix: String?)
  /// Play only the earcon.
  case earconOnly(Earcon)
  /// Say nothing.
  case drop
}

struct SoundsSituation: Equatable, Sendable {
  var earconsOn = true
  var earconsOnly = false
  var sayInsteadOfBeeping = false
  var conversation = false
}

enum SoundsPolicy {
  static func plan(text: String, kind: AnnouncementKind, earcon: Earcon?, situation: SoundsSituation) -> LinePlan {
    let tone = situation.earconsOn ? earcon : nil
    if situation.conversation, !ConversationMode.isOwnLine(text) {
      if let tone, !situation.sayInsteadOfBeeping { return .earconOnly(tone) }
      return .drop
    }
    if situation.sayInsteadOfBeeping, let earcon, let meaning = earcon.spokenMeaning {
      return .speak(earcon: nil, prefix: meaning)
    }
    if situation.earconsOnly, kind == .status, let tone { return .earconOnly(tone) }
    return .speak(earcon: tone, prefix: nil)
  }

  /// A standalone earcon (not part of a line): spoken instead while learning, if it has a meaning.
  static func spokenInsteadOfTone(_ earcon: Earcon, situation: SoundsSituation) -> String? {
    guard situation.sayInsteadOfBeeping, situation.earconsOn, !situation.conversation else { return nil }
    return earcon.spokenMeaning
  }

  @MainActor
  static var current: SoundsSituation {
    let values = SoundsArea.shared.values
    return SoundsSituation(
      earconsOn: A11yPreferences.shared.earconsEnabled, earconsOnly: values.earconsOnly,
      sayInsteadOfBeeping: values.sayInsteadOfBeeping, conversation: ConversationMode.shared.isActive)
  }

  /// Announcer's entry point.
  @MainActor
  static func plan(text: String, kind: AnnouncementKind, earcon: Earcon?) -> LinePlan {
    let plan = plan(text: text, kind: kind, earcon: earcon, situation: current)
    if plan != .speak(earcon: earcon, prefix: nil), ConversationMode.shared.isActive { ConversationMode.shared.noteHeldBack() }
    return plan
  }
}

extension Earcon {
  /// What the earcon means, in words, for "say it instead of beeping". nil for tones that mark the
  /// microphone or a wait: saying those would talk over the user or never stop.
  /// None of these words is a voice command, so hearing them back can't trigger anything.
  var spokenMeaning: String? {
    switch self {
    case .ready: "Ready"
    case .connected: "Connected"
    case .disconnected: "Disconnected"
    case .done: "Finished"
    case .error: "Problem"
    case .uncertain: "Not sure"
    case .attention: "Heads up"
    case .listening, .capturing, .working, .heard: nil
    }
  }
}
