/*
 * SettingsStore - undo, "keep that", lock, "what's my setup", resets, profiles and share codes for
 * every Make it your own area (notes/customisation-roadmap.md C0, notes/customisation-ios-core.md)
 *
 * It fills in SettingsChanges.handler and isLocked, so every area's user-made change lands here
 * with the area's snapshot from before it.
 *
 * The keep rule (design rule 1):
 * - A change made by voice applies at once, for this session. "Keep that" saves it. A voice change
 *   that wasn't kept goes back to the kept value on the next launch (revertUnkeptChanges, run at
 *   start-up). The first unkept change of a session says "Say keep that to keep it."
 * - A change made on the screen is kept at once: tapping a setting is already deliberate.
 * - Profile switches, saves, resets and imports are deliberate too, so they are kept at once.
 * - Everything is undoable, newest first, for the whole session ("undo", "put it back").
 *
 * How it tells voice from screen: SettingsVoiceGate runs every settings grammar inside
 * voiceChange { }, and VoiceControl's faster, slower and answers commands go through
 * SpeechChanges, which does the same. Anything recorded outside it came from the screen.
 *
 * Learned suggestions (rule 9): the same voice tweak three times asks "Make short answers the
 * default? Say yes or no." and keeps it only on yes. Counted per profile.
 *
 * Storage keys (UserDefaults): settings.locked, settings.unkept (area IDs), settings.baseline.<id>
 * (the kept snapshot of an area with an unkept change), settings.tweaks, plus the profile keys in
 * SettingsStore+Profiles.swift.
 */

import Foundation
import Observation

@MainActor
@Observable
final class SettingsStore {
  static let shared = SettingsStore()

  struct UndoEntry {
    /// Each touched area's snapshot from before the change.
    var befores: [String: Data]
    var description: String
    var at: Date
    var kept: Bool
    /// Profiles and the active profile from before, when the change touched them.
    var profilesBefore: [SettingsProfile]?
    var activeProfileBefore: String?
  }

  /// Newest last. Session only: undo doesn't survive a relaunch.
  private(set) var undoStack: [UndoEntry] = []
  private(set) var isLocked: Bool
  /// Areas with a voice change that hasn't been kept yet.
  private(set) var unkeptAreas: Set<String>
  /// Named setups (SettingsStore+Profiles.swift).
  var profiles: [SettingsProfile] = []
  var activeProfile: String = SettingsProfile.homeName

  @ObservationIgnored let defaults: UserDefaults
  @ObservationIgnored var areas: @MainActor () -> [any SettingsArea]
  @ObservationIgnored var now: @MainActor () -> Date
  /// Puts a yes-or-no question to voice control. The question itself is in the reply.
  @ObservationIgnored var ask: @MainActor (_ yes: @escaping @MainActor () -> Void, _ no: @escaping @MainActor () -> Void) -> Void
  /// Speaks a line that comes later than the reply (after a yes).
  @ObservationIgnored var say: @MainActor (String) -> Void

  @ObservationIgnored private var voiceDepth = 0
  @ObservationIgnored private var deliberateDepth = 0
  @ObservationIgnored var groupDepth = 0
  @ObservationIgnored private var followUps: [String] = []
  @ObservationIgnored private var keepHintGiven = false

  static let maxUndo = 30
  /// Screen changes to the same area this close together are one undo step (a stepper held down).
  static let coalesceWindow: TimeInterval = 3
  /// The same voice tweak this many times brings the "make it the default?" question.
  static let suggestAfter = 3

  enum Key {
    static let locked = "settings.locked"
    static let unkept = "settings.unkept"
    static let tweaks = "settings.tweaks"
    static func baseline(_ areaID: String) -> String { "settings.baseline.\(areaID)" }
  }

  init(
    defaults: UserDefaults = .standard,
    areas: @escaping @MainActor () -> [any SettingsArea] = { SettingsAreas.all },
    now: @escaping @MainActor () -> Date = { Date() },
    ask: @escaping @MainActor (_ yes: @escaping @MainActor () -> Void, _ no: @escaping @MainActor () -> Void) -> Void = { yes, no in
      VoiceControl.shared.ask(yes: yes, no: no)
    },
    say: @escaping @MainActor (String) -> Void = { Announcer.shared.say($0, kind: .reply) }
  ) {
    self.defaults = defaults
    self.areas = areas
    self.now = now
    self.ask = ask
    self.say = say
    isLocked = defaults.bool(forKey: Key.locked)
    unkeptAreas = Set(defaults.stringArray(forKey: Key.unkept) ?? [])
    loadProfiles()
  }

  /// Becomes the handler every area reports to. Once, at start-up.
  func install() {
    SettingsChanges.handler = { [weak self] areaID, before, description in
      self?.record(areaID, before: before, description: description)
    }
    SettingsChanges.isLocked = { [weak self] in self?.isLocked ?? false }
  }

  func area(_ id: String) -> (any SettingsArea)? {
    areas().first { type(of: $0).areaID == id }
  }

  private func id(of area: any SettingsArea) -> String { type(of: area).areaID }

  // MARK: Where a change comes from

  /// Runs `body` as a voice change: what it records is for this session until "keep that".
  func voiceChange<T>(_ body: () -> T) -> T {
    voiceDepth += 1
    defer { voiceDepth -= 1 }
    return body()
  }

  /// Runs `body` as a deliberate change (keep this voice, a profile, an import): kept at once even
  /// when said by voice.
  func deliberately<T>(_ body: () -> T) -> T {
    deliberateDepth += 1
    defer { deliberateDepth -= 1 }
    return body()
  }

  var isVoiceChange: Bool { voiceDepth > 0 && deliberateDepth == 0 }

  /// What to say after the reply: the keep hint or a learned suggestion. Cleared once taken.
  func takeFollowUp() -> String? {
    defer { followUps.removeAll() }
    return followUps.isEmpty ? nil : followUps.joined(separator: " ")
  }

  // MARK: Recording

  /// SettingsChanges.handler. An area calls it with its snapshot from before a user-made change.
  func record(_ areaID: String, before: Data, description: String) {
    guard groupDepth == 0 else { return }  // a group (profile, reset, import) holds its own befores
    let kept = !isVoiceChange
    if kept {
      // Screen changes keep the area as it now is, earlier voice changes included.
      clearUnkept([areaID])
    } else {
      markUnkept(areaID, baseline: before)
      if !keepHintGiven {
        keepHintGiven = true
        followUps.append(SettingsLines.keepHint)
      }
    }
    let time = now()
    if kept, let last = undoStack.last, last.kept, last.profilesBefore == nil, Array(last.befores.keys) == [areaID],
      time.timeIntervalSince(last.at) < Self.coalesceWindow
    {
      undoStack[undoStack.count - 1].description = description
      undoStack[undoStack.count - 1].at = time
      return
    }
    push(UndoEntry(befores: [areaID: before], description: description, at: time, kept: kept))
  }

  private func push(_ entry: UndoEntry) {
    undoStack.append(entry)
    if undoStack.count > Self.maxUndo { undoStack.removeFirst(undoStack.count - Self.maxUndo) }
  }

  private func markUnkept(_ areaID: String, baseline: Data) {
    guard !unkeptAreas.contains(areaID) else { return }
    defaults.set(baseline, forKey: Key.baseline(areaID))
    unkeptAreas.insert(areaID)
    defaults.set(unkeptAreas.sorted(), forKey: Key.unkept)
  }

  func clearUnkept(_ areaIDs: some Sequence<String>) {
    var changed = false
    for id in areaIDs where unkeptAreas.contains(id) {
      unkeptAreas.remove(id)
      defaults.removeObject(forKey: Key.baseline(id))
      changed = true
    }
    if changed { defaults.set(unkeptAreas.sorted(), forKey: Key.unkept) }
  }

  func baseline(_ areaID: String) -> Data? {
    unkeptAreas.contains(areaID) ? defaults.data(forKey: Key.baseline(areaID)) : nil
  }

  /// Runs `body` as one deliberate, undoable step over every area (or `areaIDs`). Areas restored
  /// or reset inside don't record their own steps.
  func group(
    _ description: String, areaIDs: [String]? = nil, touchesProfiles: Bool = false, _ body: () -> Void
  ) {
    let touched = areas().filter { areaIDs?.contains(id(of: $0)) ?? true }
    var befores: [String: Data] = [:]
    for area in touched { befores[id(of: area)] = area.snapshot() }
    let entry = UndoEntry(
      befores: befores, description: description, at: now(), kept: true,
      profilesBefore: touchesProfiles ? profiles : nil, activeProfileBefore: touchesProfiles ? activeProfile : nil)
    groupDepth += 1
    body()
    groupDepth -= 1
    clearUnkept(befores.keys)
    push(entry)
  }

  // MARK: Undo, keep, lock

  func undo() -> String {
    if isLocked { return SettingsLines.locked }
    guard let entry = undoStack.popLast() else { return SettingsLines.nothingToUndo }
    groupDepth += 1
    for (id, data) in entry.befores { try? area(id)?.restore(data) }
    groupDepth -= 1
    if let profilesBefore = entry.profilesBefore {
      profiles = profilesBefore
      activeProfile = entry.activeProfileBefore ?? activeProfile
      saveProfiles()
    }
    // Back where the kept value was: nothing left to keep for that area.
    for id in entry.befores.keys {
      if let baseline = baseline(id), let area = area(id), area.snapshot() == baseline { clearUnkept([id]) }
    }
    let now = describe(areaIDs: Array(entry.befores.keys))
    return "Undone: \(entry.description). " + (now.isEmpty ? "" : "Now \(now).")
  }

  func keep() -> String {
    if isLocked { return SettingsLines.locked }
    guard !unkeptAreas.isEmpty else { return SettingsLines.nothingToKeep }
    let ids = unkeptAreas.sorted()
    clearUnkept(ids)
    saveActiveProfile()
    let now = describe(areaIDs: ids)
    return now.isEmpty ? "Kept." : "Kept: \(now)."
  }

  func lock() -> String {
    guard !isLocked else { return SettingsLines.alreadyLocked }
    isLocked = true
    defaults.set(true, forKey: Key.locked)
    return SettingsLines.lockedNow
  }

  func unlock() -> String {
    guard isLocked else { return SettingsLines.alreadyUnlocked }
    isLocked = false
    defaults.set(false, forKey: Key.locked)
    return SettingsLines.unlockedNow
  }

  // MARK: What's my setup

  /// Only what differs from the defaults, from every area, plus the profile, what isn't kept yet,
  /// and the lock.
  func whatsMySetup() -> String {
    var parts: [String] = []
    if profiles.count > 1 || activeProfile != SettingsProfile.homeName { parts.append("Profile: \(activeProfile).") }
    let differences = areas().flatMap { $0.differencesFromDefaults() }
    parts.append(differences.isEmpty ? SettingsLines.allDefaults : "Changed from the defaults: \(SettingsWords.list(differences)).")
    if !unkeptAreas.isEmpty {
      let names = unkeptAreas.sorted().map { area($0)?.spokenName ?? $0 }
      parts.append("Not kept yet: \(SettingsWords.list(names)). Say keep that to keep it.")
    }
    if isLocked { parts.append("Settings are locked.") }
    return parts.joined(separator: " ")
  }

  /// "speech 1.2 times and short answers", or "speech at the defaults".
  func describe(areaIDs: [String]) -> String {
    let parts = areaIDs.sorted().compactMap { id -> String? in
      guard let area = area(id) else { return nil }
      let differences = area.differencesFromDefaults()
      return differences.isEmpty ? "\(area.spokenName) at the defaults" : SettingsWords.list(differences)
    }
    return SettingsWords.list(parts)
  }

  /// A short summary of the whole setup for profile switches and imports: up to four changes.
  func shortSummary() -> String {
    let differences = areas().flatMap { $0.differencesFromDefaults() }
    if differences.isEmpty { return "everything at the defaults" }
    let shown = Array(differences.prefix(4))
    return SettingsWords.list(shown) + (differences.count > shown.count ? ", and more" : "")
  }

  // MARK: Resets

  /// "reset speech". Undoable.
  func reset(areaID: String) -> String {
    if isLocked { return SettingsLines.locked }
    guard let area = area(areaID) else { return SettingsLines.noSuchArea(areaID) }
    group("reset \(area.spokenName)", areaIDs: [areaID]) { area.resetToDefaults() }
    return "\(SettingsWords.sentence(area.spokenName)) is back to the defaults. Say undo to put it back."
  }

  /// "reset everything": asks first. The answer comes through voice control's yes or no.
  func requestResetEverything() -> String {
    if isLocked { return SettingsLines.locked }
    ask(
      { [weak self] in
        guard let self else { return }
        self.say(self.resetEverything())
      },
      { [weak self] in self?.say(SettingsLines.nothingChanged) })
    return SettingsLines.resetEverythingQuestion
  }

  /// Every area back to the defaults, as one undoable step. Profiles are kept.
  func resetEverything() -> String {
    if isLocked { return SettingsLines.locked }
    group("reset everything") {
      for area in areas() { area.resetToDefaults() }
    }
    return SettingsLines.resetEverythingDone
  }

  // MARK: Launch

  /// Voice changes that weren't kept go back to their kept value. Returns the areas put back.
  @discardableResult
  func revertUnkeptChanges() -> [String] {
    var reverted: [String] = []
    groupDepth += 1
    for id in unkeptAreas.sorted() {
      guard let data = defaults.data(forKey: Key.baseline(id)), let area = area(id) else { continue }
      try? area.restore(data)
      reverted.append(area.spokenName)
    }
    groupDepth -= 1
    clearUnkept(unkeptAreas)
    return reverted
  }

  // MARK: Learned suggestions

  /// A voice tweak: `key` names it ("speech.verbosity.short"), `suggestion` is what the question
  /// offers ("short answers"). The third time in a profile asks to make it the default.
  func noteTweak(_ key: String, suggestion: String) {
    guard isVoiceChange else { return }
    var counts = defaults.dictionary(forKey: Key.tweaks) as? [String: Int] ?? [:]
    let countKey = "\(activeProfile)|\(key)"
    counts[countKey, default: 0] += 1
    let reached = counts[countKey, default: 0] >= Self.suggestAfter
    if reached { counts[countKey] = 0 }
    defaults.set(counts, forKey: Key.tweaks)
    guard reached, !unkeptAreas.isEmpty else { return }
    let forProfile = activeProfile == SettingsProfile.homeName ? "" : " for \(activeProfile)"
    followUps.removeAll { $0 == SettingsLines.keepHint }
    followUps.append("That's three times. Make \(suggestion) the default\(forProfile)? Say yes or no.")
    ask(
      { [weak self] in
        guard let self else { return }
        self.say(self.keep())
      },
      { [weak self] in self?.say(SettingsLines.justForNow) })
  }
}

/// What the store says. British spelling; every line says what happened or what to say next.
enum SettingsLines {
  static let locked = "Settings are locked. Say unlock settings first."
  static let lockedNow = "Settings locked. Nothing changes until you say unlock settings."
  static let alreadyLocked = "Settings are already locked."
  static let unlockedNow = "Settings unlocked."
  static let alreadyUnlocked = "Settings aren't locked."
  static let nothingToUndo = "There's nothing to undo."
  static let nothingToKeep = "Nothing new to keep. Your settings are already saved."
  static let keepHint = "Say keep that to keep it."
  static let justForNow = "Okay, just for now."
  static let nothingChanged = "Okay, nothing changed."
  static let allDefaults = "Everything is at the defaults."
  static let resetEverythingQuestion =
    "Reset everything? Every setting goes back to the defaults. You can still say undo afterwards. Say yes or no."
  static let resetEverythingDone = "Everything is back to the defaults. Say undo to put it all back."

  static func noSuchArea(_ name: String) -> String {
    "There are no \(name) settings on this phone yet."
  }
}
