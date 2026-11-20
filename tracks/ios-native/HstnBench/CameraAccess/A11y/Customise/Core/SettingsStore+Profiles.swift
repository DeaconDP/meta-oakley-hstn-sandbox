/*
 * SettingsStore+Profiles - named setups (notes/customisation-roadmap.md C5)
 *
 * A profile bundles every registered area's snapshot. Starters: Home (the user's setup as it was
 * when profiles first ran), Out and about (terse, earcons first, fewer tips) and Reading (detailed,
 * a little slower, longer pauses). A starter that hasn't been used yet is built from Home plus its
 * overrides (SettingsProfile.starterOverrides), so it carries the user's own voice and speed.
 *
 * - "switch to out and about" saves the kept state of the profile being left, then applies the
 *   new one as one undoable step. A manual choice always wins: there is no automatic switching
 *   yet, and any later trigger must not override a choice made by hand this session.
 * - "save as profile <name>" saves the setup as it is now (and keeps it) under that name.
 * - "keep that" also updates the active profile.
 *
 * Storage: settings.profiles (JSON array of SettingsProfile), settings.activeProfile.
 */

import Foundation

struct SettingsProfile: Codable, Equatable, Sendable {
  static let homeName = "Home"
  static let outAndAboutName = "Out and about"
  static let readingName = "Reading"
  static let starterNames = [homeName, outAndAboutName, readingName]

  var name: String
  /// Area ID to that area's snapshot, as JSON text.
  var areas: [String: String]

  /// What each starter changes from Home, by area, as JSON objects merged over Home's snapshot.
  /// Other areas (sounds, ears, words) add theirs at start-up, e.g. earcons first for Out and about.
  @MainActor static var starterOverrides: [String: [String: String]] = [
    outAndAboutName: [
      "speech": #"{"rate":1.2,"verbosity":"short"}"#,
      "tips": #"{"pacing":"fewer"}"#,
      "descriptions": #"{"detail":"short","directions":"clockFace"}"#,
    ],
    readingName: [
      "speech": #"{"pause":0.2,"rate":0.9,"verbosity":"detailed"}"#,
      "tips": #"{"pacing":"fewer"}"#,
    ],
  ]

  /// `base` with `override`'s top-level keys put over it. Either may be empty or not JSON.
  static func overlay(_ base: String?, with override: String) -> String {
    let parse: (String?) -> [String: Any] = { text in
      guard let data = text?.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return [:] }
      return object
    }
    var merged = parse(base)
    for (key, value) in parse(override) { merged[key] = value }
    guard let data = try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys]) else { return override }
    return String(decoding: data, as: UTF8.self)
  }
}

extension SettingsStore {
  enum ProfileKey {
    static let profiles = "settings.profiles"
    static let active = "settings.activeProfile"
  }

  func loadProfiles() {
    if let data = defaults.data(forKey: ProfileKey.profiles),
      let stored = try? JSONDecoder().decode([SettingsProfile].self, from: data)
    {
      profiles = stored
    }
    activeProfile = defaults.string(forKey: ProfileKey.active) ?? SettingsProfile.homeName
  }

  func saveProfiles() {
    defaults.set(SettingsWords.encode(profiles), forKey: ProfileKey.profiles)
    defaults.set(activeProfile, forKey: ProfileKey.active)
  }

  /// First run of profiles: Home is the setup as it is now. Call after the areas are registered.
  func seedProfilesIfNeeded() {
    guard profiles.isEmpty else { return }
    profiles = [SettingsProfile(name: SettingsProfile.homeName, areas: keptState())]
    activeProfile = SettingsProfile.homeName
    saveProfiles()
  }

  /// Every area's kept state: the baseline for an area with an unkept change, else as it is.
  func keptState() -> [String: String] {
    var state: [String: String] = [:]
    for area in areas() {
      let id = type(of: area).areaID
      state[id] = String(decoding: baseline(id) ?? area.snapshot(), as: UTF8.self)
    }
    return state
  }

  /// The kept state goes into the active profile.
  func saveActiveProfile() {
    let state = keptState()
    if let index = profiles.firstIndex(where: { $0.name == activeProfile }) {
      profiles[index].areas.merge(state) { _, new in new }
    } else {
      profiles.append(SettingsProfile(name: activeProfile, areas: state))
    }
    saveProfiles()
  }

  /// Every profile name, saved ones first, then starters not used yet.
  var profileNames: [String] {
    var names = profiles.map(\.name)
    for starter in SettingsProfile.starterNames where !names.contains(where: { $0.caseInsensitiveCompare(starter) == .orderedSame }) {
      names.append(starter)
    }
    return names
  }

  /// A saved profile, or a starter built from Home, by name in any case.
  func profile(named name: String) -> SettingsProfile? {
    let wanted = name.trimmingCharacters(in: .whitespaces)
    if let saved = profiles.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) { return saved }
    guard let starter = SettingsProfile.starterNames.first(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame })
    else { return nil }
    let home = profiles.first { $0.name == SettingsProfile.homeName }?.areas ?? keptState()
    var areas = home
    for (id, override) in SettingsProfile.starterOverrides[starter] ?? [:] {
      areas[id] = SettingsProfile.overlay(home[id], with: override)
    }
    return SettingsProfile(name: starter, areas: areas)
  }

  /// "switch to out and about". Undoable; kept at once.
  func switchProfile(to name: String) -> String {
    if isLocked { return SettingsLines.locked }
    guard let target = profile(named: name) else { return "There's no profile called \(name). Say list profiles to hear them." }
    if target.name == activeProfile, unkeptAreas.isEmpty { return "You're already using \(target.name)." }
    saveActiveProfile()
    group("profile \(target.name)", touchesProfiles: true) {
      for area in areas() {
        guard let json = target.areas[type(of: area).areaID] else { continue }
        try? area.restore(Data(json.utf8))
      }
      if !profiles.contains(where: { $0.name == target.name }) { profiles.append(target) }
      activeProfile = target.name
      saveProfiles()
    }
    return "\(target.name). Now \(shortSummary()). Say undo to go back."
  }

  /// "save as profile walking". Saves the setup as it is now, kept, and makes it the active one.
  func saveProfile(named rawName: String) -> String {
    if isLocked { return SettingsLines.locked }
    let name = SettingsWords.sentence(rawName.trimmingCharacters(in: .whitespaces))
    guard !name.isEmpty else { return "Say save as profile, then a name." }
    group("save profile \(name)", areaIDs: [], touchesProfiles: true) {
      let state = Dictionary(uniqueKeysWithValues: areas().map { (type(of: $0).areaID, String(decoding: $0.snapshot(), as: UTF8.self)) })
      if let index = profiles.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
        profiles[index].areas = state
        activeProfile = profiles[index].name
      } else {
        profiles.append(SettingsProfile(name: name, areas: state))
        activeProfile = name
      }
      saveProfiles()
    }
    clearUnkept(unkeptAreas)
    return "Saved as profile \(activeProfile). Say switch to \(activeProfile) any time."
  }

  func whichProfile() -> String {
    let unkept = unkeptAreas.isEmpty ? "" : ", with changes not kept yet"
    return "You're using \(activeProfile)\(unkept)."
  }

  func listProfiles() -> String {
    "Your profiles: \(SettingsWords.list(profileNames)). Say switch to, then a name."
  }

  /// "delete profile walking". Not Home and not the one in use. Undoable.
  func deleteProfile(named name: String) -> String {
    if isLocked { return SettingsLines.locked }
    guard let target = profiles.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
      return "There's no saved profile called \(name)."
    }
    if target.name == SettingsProfile.homeName { return "Home can't be deleted." }
    if target.name == activeProfile { return "You're using \(target.name). Switch to another profile first." }
    group("delete profile \(target.name)", areaIDs: [], touchesProfiles: true) {
      profiles.removeAll { $0.name == target.name }
      saveProfiles()
    }
    return "Deleted \(target.name). Say undo to bring it back."
  }
}
