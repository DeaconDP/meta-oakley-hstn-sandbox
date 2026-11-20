/*
 * DescriptionSettings - the "descriptions" area (notes/customisation-roadmap.md C6)
 *
 * The detail dial and description preferences for Look closer: read any text first, mention
 * colours or skip them, left and right or clock-face directions.
 *
 * Not used yet: iOS has no Look closer or cloud scene description (checked 2026-11-20). The
 * values are stored, travel in profiles and share codes, and can be set by voice and on screen,
 * so a describer added later reads them from here (SettingsAreas.area("descriptions")).
 * The privacy and "say how sure" rules aren't settings and never will be.
 *
 * Storage: settings.descriptions (this area's JSON snapshot).
 */

import Foundation
import Observation

enum DescriptionDetail: String, CaseIterable, Identifiable, Sendable {
  case short
  case normal
  case detailed

  var id: String { rawValue }
  var title: String { rawValue.capitalized }
}

enum DescriptionDirections: String, CaseIterable, Identifiable, Sendable {
  case leftRight
  case clockFace

  var id: String { rawValue }

  var title: String {
    switch self {
    case .leftRight: "Left and right"
    case .clockFace: "Clock face"
    }
  }
}

@MainActor
@Observable
final class DescriptionSettings: SettingsArea {
  static let areaID = "descriptions"
  var spokenName: String { "descriptions" }

  struct Values: Codable, Equatable {
    var detail: String?
    var textFirst: Bool?
    var colours: Bool?
    var directions: String?
  }

  private(set) var detail: DescriptionDetail = .normal
  private(set) var readTextFirst = true
  private(set) var mentionColours = true
  private(set) var directions: DescriptionDirections = .leftRight

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored var record: @MainActor (_ areaID: String, _ before: Data, _ description: String) -> Void = {
    SettingsChanges.record($0, before: $1, description: $2)
  }
  @ObservationIgnored var isLocked: @MainActor () -> Bool = { SettingsChanges.isLocked() }

  static let storageKey = "settings.descriptions"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let data = defaults.data(forKey: Self.storageKey) { apply(try? JSONDecoder().decode(Values.self, from: data)) }
  }

  private func apply(_ values: Values?) {
    detail = values?.detail.flatMap(DescriptionDetail.init(rawValue:)) ?? .normal
    readTextFirst = values?.textFirst ?? true
    mentionColours = values?.colours ?? true
    directions = values?.directions.flatMap(DescriptionDirections.init(rawValue:)) ?? .leftRight
    defaults.set(snapshot(), forKey: Self.storageKey)
  }

  func snapshot() -> Data {
    SettingsWords.encode(Values(detail: detail.rawValue, textFirst: readTextFirst, colours: mentionColours, directions: directions.rawValue))
  }

  func restore(_ data: Data) throws {
    apply(try JSONDecoder().decode(Values.self, from: data))
  }

  func resetToDefaults() { apply(nil) }

  func differencesFromDefaults() -> [String] {
    var differences: [String] = []
    if detail != .normal { differences.append("\(detail.rawValue) descriptions") }
    if !readTextFirst { differences.append("text not read first") }
    if !mentionColours { differences.append("colours skipped") }
    if directions == .clockFace { differences.append("clock-face directions") }
    return differences
  }

  // MARK: Changes

  static let notOnIPhoneYet = "Descriptions use this once Look closer comes to iPhone."

  func setDetail(_ new: DescriptionDetail) -> String {
    change("\(new.rawValue) descriptions") { $0.detail = new.rawValue }
  }

  func setReadTextFirst(_ on: Bool) -> String {
    change(on ? "read any text first" : "text not read first") { $0.textFirst = on }
  }

  func setMentionColours(_ on: Bool) -> String {
    change(on ? "mention colours" : "skip colours") { $0.colours = on }
  }

  func setDirections(_ new: DescriptionDirections) -> String {
    change(new == .clockFace ? "clock-face directions" : "left and right directions") { $0.directions = new.rawValue }
  }

  private func change(_ description: String, _ edit: (inout Values) -> Void) -> String {
    if isLocked() { return SettingsLines.locked }
    let before = snapshot()
    var values = (try? JSONDecoder().decode(Values.self, from: before)) ?? Values()
    edit(&values)
    apply(values)
    record(Self.areaID, before, description)
    return "\(SettingsWords.sentence(description)). \(Self.notOnIPhoneYet)"
  }
}
