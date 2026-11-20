/*
 * SettingsArea - the contract every "Make it your own" area follows (notes/customisation-roadmap.md)
 *
 * An area is one group of settings: speech, sounds, ears, words, controls, descriptions, tips.
 * Each area owns its values and its storage, and plugs into the shared machinery here:
 *
 * - snapshot/restore as JSON, so profiles, "undo", "keep that" and export/import work on every
 *   area without knowing its fields;
 * - differencesFromDefaults, so "what's my setup?" speaks only what the user changed;
 * - SettingsChanges.record before every user-made change, so "undo" can put it back;
 * - SettingsChanges.isLocked, so "lock settings" stops accidental changes;
 * - SettingsVoice grammars, so every setting can be changed by voice.
 *
 * Areas register themselves once (SettingsAreas.register) at app start-up.
 */

import Foundation

@MainActor
protocol SettingsArea: AnyObject {
  /// Stable key, used in storage, profiles and export codes: "speech", "sounds", "ears", ...
  static var areaID: String { get }
  /// What the user calls it: "speech", "sounds", "your ears".
  var spokenName: String { get }
  /// Current values as JSON.
  func snapshot() -> Data
  /// Applies values from `snapshot()`. Unknown or missing fields keep their defaults.
  func restore(_ data: Data) throws
  /// Back to the defaults for this area only ("reset speech").
  func resetToDefaults()
  /// Short spoken phrases for each value that differs from the default, e.g. "speech 1.4 times".
  func differencesFromDefaults() -> [String]
}

@MainActor
enum SettingsAreas {
  private(set) static var all: [any SettingsArea] = []

  static func register(_ area: any SettingsArea) {
    let id = type(of: area).areaID
    all.removeAll { type(of: $0).areaID == id }
    all.append(area)
  }

  static func area(_ id: String) -> (any SettingsArea)? {
    all.first { type(of: $0).areaID == id }
  }
}

/// Hooks an area calls around a user-made change. The settings store fills them in.
@MainActor
enum SettingsChanges {
  /// Set by the settings store: records the area's snapshot from before a change, plus a spoken
  /// description of the new value ("speech faster, 1.2 times"), for "undo" and "keep that".
  static var handler: ((_ areaID: String, _ before: Data, _ description: String) -> Void)?

  /// Set by the settings store. While true, areas refuse user changes and say so.
  static var isLocked: () -> Bool = { false }

  static func record(_ areaID: String, before: Data, description: String) {
    handler?(areaID, before, description)
  }
}

/// One voice grammar for settings. Returns the spoken reply when it handled the utterance, nil
/// when the words aren't for it. Grammars must not claim words that existing VoiceCommand phrases use.
@MainActor
protocol SettingsGrammar {
  func handle(_ utterance: String) -> String?
}

@MainActor
enum SettingsVoice {
  private(set) static var grammars: [any SettingsGrammar] = []

  static func register(_ grammar: any SettingsGrammar) { grammars.append(grammar) }

  /// Tries each grammar in order; the first reply wins.
  static func route(_ utterance: String) -> String? {
    for grammar in grammars {
      if let reply = grammar.handle(utterance) { return reply }
    }
    return nil
  }
}
