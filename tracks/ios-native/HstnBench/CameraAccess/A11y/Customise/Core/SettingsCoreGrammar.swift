/*
 * SettingsCoreGrammar - the voice phrases that work across every area (C0, J5)
 *
 * undo, keep that, lock and unlock, what's my setup, reset <area> and reset everything, profiles,
 * share codes, and settings help. Whole phrases after filler; none is a VoiceCommand phrase.
 * Phrase lists: notes/customisation-ios-core.md.
 */

import Foundation
import UIKit

@MainActor
struct SettingsCoreGrammar: SettingsGrammar {
  let store: SettingsStore
  /// Clipboard seams, so tests don't touch the real pasteboard.
  var copy: @MainActor (String) -> Void = { UIPasteboard.general.string = $0 }
  var paste: @MainActor () -> String? = { UIPasteboard.general.string }

  static let undo: Set<String> = [
    "undo", "undo that", "undo it", "put it back", "put that back", "undo the last change", "undo last change", "take that back",
    "change it back", "change that back",
  ]
  static let keep: Set<String> = [
    "keep that", "keep it", "keep this", "keep those", "keep these", "keep the change", "keep the changes", "keep that setting",
    "save that", "save that setting", "make that the default",
  ]
  static let lock: Set<String> = ["lock settings", "lock my settings", "lock the settings", "lock setting"]
  static let unlock: Set<String> = ["unlock settings", "unlock my settings", "unlock the settings", "unlock setting"]
  static let setup: Set<String> = [
    "whats my setup", "what is my setup", "my setup", "describe my setup", "what have i changed", "what did i change",
    "read my setup", "whats changed", "what settings have i changed", "tell me my setup",
  ]
  static let resetEverything: Set<String> = [
    "reset everything", "reset all", "reset all settings", "reset all my settings", "reset my settings", "reset all the settings",
    "reset settings",
  ]
  static let whichProfile: Set<String> = [
    "which profile", "what profile", "which profile am i using", "what profile am i using", "which profile is on", "current profile",
    "what profile is on",
  ]
  static let listProfiles: Set<String> = ["list profiles", "what profiles are there", "what profiles do i have", "my profiles", "profiles"]
  static let share: Set<String> = [
    "copy my setup", "share my setup", "copy setup code", "copy my setup code", "share setup", "export my setup", "export setup",
    "share my settings", "copy my settings",
  ]
  static let importSetup: Set<String> = [
    "paste a setup", "paste setup", "paste my setup", "import setup", "import a setup", "use the copied setup", "paste setup code",
    "import setup code", "paste the setup", "import my setup",
  ]
  static let help: Set<String> = ["settings help", "what can i change", "help with settings", "what settings can i change"]

  /// Area names people use for "reset <area>", beyond each area's own ID and spoken name.
  static let areaAliases: [String: String] = [
    "voice": "speech", "the voice": "speech", "my voice": "speech", "speaking": "speech", "the speech": "speech",
    "nudges": "tips", "reminders": "tips", "spoken tips": "tips", "the tips": "tips",
    "description": "descriptions", "the descriptions": "descriptions",
    "sound": "sounds", "the sounds": "sounds", "earcons": "sounds",
    "ears": "ears", "my ears": "ears", "your ears": "ears",
    "words": "words", "my words": "words", "your words": "words",
    "buttons": "controls", "controls": "controls", "my buttons": "controls",
  ]

  static let helpLine =
    "You can say: faster, slower, higher voice, longer pauses, brisk, gentle, try another voice, short answers for mail, "
    + "fewer tips, undo, keep that, what's my setup, reset speech, lock settings, switch to out and about, "
    + "save as profile then a name, and copy my setup."

  func handle(_ utterance: String) -> String? {
    let p = SettingsWords.phrase(utterance)
    guard !p.isEmpty else { return nil }
    if Self.undo.contains(p) { return store.undo() }
    if Self.keep.contains(p) { return store.keep() }
    if Self.lock.contains(p) { return store.lock() }
    if Self.unlock.contains(p) { return store.unlock() }
    if Self.setup.contains(p) { return store.whatsMySetup() }
    if Self.resetEverything.contains(p) { return store.requestResetEverything() }
    if p == "reset" { return "Say reset, then speech, tips, descriptions, or everything." }
    if let rest = SettingsWords.rest(of: p, after: "reset") { return resetArea(rest) }
    if Self.whichProfile.contains(p) { return store.whichProfile() }
    if Self.listProfiles.contains(p) { return store.listProfiles() }
    if Self.share.contains(p) {
      copy(store.exportCode())
      return "Your setup code is copied. Paste it into a message, or into SpeakUp on another phone with paste a setup."
    }
    if Self.importSetup.contains(p) {
      guard let text = paste(), !text.isEmpty else { return "There's nothing copied. Copy a SpeakUp setup code first." }
      return store.importSetup(text)
    }
    if Self.help.contains(p) { return Self.helpLine }
    if let reply = profiles(p) { return reply }
    return nil
  }

  private func resetArea(_ words: String) -> String? {
    let id = Self.areaAliases[words] ?? words
    if let area = store.area(id) ?? store.areas().first(where: { $0.spokenName == words }) {
      return store.reset(areaID: type(of: area).areaID)
    }
    // Known names of areas that aren't on this build yet; anything else isn't for settings.
    let known = Set(Self.areaAliases.values)
    return known.contains(id) ? SettingsLines.noSuchArea(words) : nil
  }

  private func profiles(_ p: String) -> String? {
    for prefix in ["save as profile", "save profile as", "save this as profile", "save as a profile", "save this as a profile", "new profile", "save profile"] {
      if let name = SettingsWords.rest(of: p, after: prefix) { return store.saveProfile(named: name) }
    }
    for prefix in ["delete profile", "remove profile", "delete the profile", "remove the profile"] {
      if let name = SettingsWords.rest(of: p, after: prefix) { return store.deleteProfile(named: Self.profileName(name)) }
    }
    for prefix in ["switch to", "change to", "switch profile to", "change profile to", "use", "go to", "use profile"] {
      guard let rest = SettingsWords.rest(of: p, after: prefix) else { continue }
      let name = Self.profileName(rest)
      // Only a profile's name: "switch to the phone" stays the camera's.
      if store.profile(named: name) != nil { return store.switchProfile(to: name) }
    }
    if p.hasSuffix(" profile") {
      let name = Self.profileName(p)
      if store.profile(named: name) != nil { return store.switchProfile(to: name) }
    }
    return nil
  }

  /// "the reading profile" -> "reading".
  static func profileName(_ words: String) -> String {
    var name = words
    if name.hasPrefix("the ") { name = String(name.dropFirst(4)) }
    if name.hasPrefix("my ") { name = String(name.dropFirst(3)) }
    if name.hasSuffix(" profile") { name = String(name.dropLast(8)) }
    return name
  }
}

/// The one door from VoiceControl into the settings grammars: everything said goes through every
/// registered grammar as a voice change, with the store's follow-up (keep hint, suggestion) after.
@MainActor
enum SettingsVoiceGate {
  /// A tool is waiting for free words (Watch asking what to watch for), so settings stay out of it.
  static var isCaptureActive: @MainActor () -> Bool = { false }

  static func route(_ text: String) -> String? {
    guard !isCaptureActive() else { return nil }
    let store = SettingsStore.shared
    let reply = store.voiceChange { SettingsVoice.route(text) }
    let followUp = store.takeFollowUp()
    guard let reply else { return nil }
    return [reply, followUp].compactMap { $0 }.joined(separator: " ")
  }
}
