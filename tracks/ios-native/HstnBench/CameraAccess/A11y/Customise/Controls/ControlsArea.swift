/*
 * ControlsArea - "Your buttons" as a SettingsArea: the glasses event map, glasses buttons on or
 * off, and the favourite tool (notes/customisation-ios-words.md)
 *
 * Same pattern as WordsArea: every user change refuses while locked, records the snapshot from
 * before, saves (UserDefaults "customise.controls.v1") and returns the line to say.
 */

import Foundation
import Observation

@MainActor
@Observable
final class ControlsArea: SettingsArea {
  static let shared = ControlsArea(defaults: .standard)

  static let areaID = "controls"
  static let storageKey = "customise.controls.v1"

  var spokenName: String { "your buttons" }

  private(set) var settings: ControlsSettings

  /// Called when glasses buttons are switched on or off, so the glasses side can add or remove
  /// the Inputs capability. Set by the DAT build (DATGlassesInputs).
  @ObservationIgnored var onEnabledChanged: (@MainActor (Bool) -> Void)?

  @ObservationIgnored private let defaults: UserDefaults

  init(defaults: UserDefaults) {
    self.defaults = defaults
    if let data = defaults.data(forKey: Self.storageKey), let stored = try? JSONDecoder().decode(ControlsSettings.self, from: data) {
      settings = stored
    } else {
      settings = ControlsSettings()
    }
  }

  var enabled: Bool { settings.enabled }
  var favouriteTool: ToolID? { settings.favouriteTool }
  func action(for control: GlassesControl) -> ControlAction { settings.action(for: control) }

  // MARK: SettingsArea

  func snapshot() -> Data { (try? WordsText.encoder.encode(settings)) ?? Data() }

  func restore(_ data: Data) throws {
    let wasEnabled = settings.enabled
    settings = try JSONDecoder().decode(ControlsSettings.self, from: data)
    save(wasEnabled: wasEnabled)
  }

  func resetToDefaults() {
    let wasEnabled = settings.enabled
    settings = ControlsSettings()
    save(wasEnabled: wasEnabled)
  }

  func differencesFromDefaults() -> [String] {
    var lines: [String] = []
    if !settings.enabled { lines.append("glasses buttons off") }
    for control in GlassesControl.allCases where settings.action(for: control) != ControlsSettings().action(for: control) {
      lines.append("\(control.spokenName) will \(settings.action(for: control).spokenName)")
    }
    if let favourite = settings.favouriteTool { lines.append("favourite tool \(favourite.title.lowercased())") }
    return lines
  }

  // MARK: Changes

  private func change(_ description: String, _ apply: (inout ControlsSettings) -> String) -> String {
    if SettingsChanges.isLocked() { return SpokenMessage.customiseLocked }
    var next = settings
    let line = apply(&next)
    guard next != settings else { return line }
    SettingsChanges.record(Self.areaID, before: snapshot(), description: description)
    let wasEnabled = settings.enabled
    settings = next
    save(wasEnabled: wasEnabled)
    return line
  }

  func set(_ control: GlassesControl, to action: ControlAction) -> String {
    if settings.action(for: control) == action, !SettingsChanges.isLocked() {
      return SpokenMessage.controlsAlready(control, action)
    }
    return change("\(control.spokenName), \(action.spokenName)") { settings in
      settings.map[control] = action
      return SpokenMessage.controlsSet(control, action)
    }
  }

  func setEnabled(_ on: Bool) -> String {
    if settings.enabled == on, !SettingsChanges.isLocked() {
      return on ? SpokenMessage.controlsAlreadyOn : SpokenMessage.controlsAlreadyOff
    }
    return change(on ? "glasses buttons on" : "glasses buttons off") { settings in
      settings.enabled = on
      return on ? SpokenMessage.controlsOn : SpokenMessage.controlsOff
    }
  }

  func setFavourite(_ tool: ToolID?) -> String {
    change(tool.map { "favourite tool \($0.title.lowercased())" } ?? "no favourite tool") { settings in
      settings.favouriteTool = tool
      return tool.map(SpokenMessage.favouriteSet) ?? SpokenMessage.favouriteNone
    }
  }

  /// "What do my buttons do?": every mapped control, then Meta's reserved gestures.
  func readBack(glassesSupported: Bool = GlassesSupport.isBuiltIn) -> String {
    guard glassesSupported else { return SpokenMessage.controlsNeedGlassesBuild }
    guard settings.enabled else { return "\(SpokenMessage.controlsOff) Say glasses buttons on to use them. \(SpokenMessage.controlsWarning)" }
    let mapped = GlassesControl.allCases.filter { settings.action(for: $0) != .nothing }
    var parts = mapped.map { "\(WordsText.capitalisedFirst($0.spokenName)) will \(settings.action(for: $0).spokenName)." }
    if mapped.isEmpty { parts.append("None of your glasses buttons do anything in SpeakUp.") }
    if let favourite = settings.favouriteTool, mapped.contains(where: { settings.action(for: $0) == .favouriteTool }) {
      parts.append("Your favourite tool is \(favourite.title.lowercased()).")
    }
    parts.append(SpokenMessage.controlsWarning)
    return parts.joined(separator: " ")
  }

  private func save(wasEnabled: Bool) {
    if let data = try? WordsText.encoder.encode(settings) { defaults.set(data, forKey: Self.storageKey) }
    if wasEnabled != settings.enabled { onEnabledChanged?(settings.enabled) }
  }
}
