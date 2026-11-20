/*
 * SettingsStore+Transfer - share and carry a whole setup (notes/customisation-roadmap.md C7)
 *
 * Two forms of the same thing:
 * - JSON: {"schema": 1, "kind": "speakup.setup", "areas": {"speech": {...}, ...},
 *   "profiles": [{"name": "Home", "areas": {...}}], "activeProfile": "Home"}
 *   Areas are each area's own snapshot, so any registered area travels without this file knowing
 *   its fields. Android reads and writes the same shape (C0 schema).
 * - A short code: "SPEAKUP1." then base64url of the zlib-compressed JSON. Fits in a text message.
 *
 * Import takes either, says a short summary of the new setup, and is one undoable step. A newer
 * schema is refused with a spoken reason. Areas this phone doesn't have are skipped.
 */

import Foundation

enum SettingsTransfer {
  static let schemaVersion = 1
  static let kind = "speakup.setup"
  static let codePrefix = "SPEAKUP1."

  enum ImportError: Error, Equatable {
    case unreadable
    case newerSchema(Int)
    case notASetup
  }

  struct Setup {
    var areas: [String: Data]
    var profiles: [SettingsProfile]
    var activeProfile: String?
  }

  static func json(areas: [String: Data], profiles: [SettingsProfile], activeProfile: String) -> Data {
    func object(_ data: Data) -> Any { (try? JSONSerialization.jsonObject(with: data)) ?? [String: Any]() }
    let root: [String: Any] = [
      "schema": schemaVersion,
      "kind": kind,
      "areas": areas.mapValues(object),
      "profiles": profiles.map { profile in
        ["name": profile.name, "areas": profile.areas.mapValues { object(Data($0.utf8)) }] as [String: Any]
      },
      "activeProfile": activeProfile,
    ]
    return (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? Data()
  }

  static func code(fromJSON json: Data) -> String {
    let compressed = (try? (json as NSData).compressed(using: .zlib) as Data) ?? json
    let base64 = compressed.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return codePrefix + base64
  }

  /// JSON text or a code, as pasted. Whitespace and line breaks inside a code are ignored.
  static func parse(_ text: String) throws -> Setup {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let json: Data
    if trimmed.hasPrefix("{") {
      json = Data(trimmed.utf8)
    } else {
      let body = trimmed.uppercased().hasPrefix(codePrefix) ? String(trimmed.dropFirst(codePrefix.count)) : trimmed
      var base64 = body.filter { !$0.isWhitespace }.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
      while base64.count % 4 != 0 { base64.append("=") }
      guard let compressed = Data(base64Encoded: base64),
        let inflated = try? (compressed as NSData).decompressed(using: .zlib) as Data
      else { throw ImportError.unreadable }
      json = inflated
    }
    guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw ImportError.unreadable }
    guard root["kind"] as? String == kind else { throw ImportError.notASetup }
    let schema = root["schema"] as? Int ?? 0
    guard schema <= schemaVersion else { throw ImportError.newerSchema(schema) }
    func data(_ object: Any) -> Data? {
      guard JSONSerialization.isValidJSONObject(object) else { return nil }
      return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    let areas = (root["areas"] as? [String: Any] ?? [:]).compactMapValues(data)
    let profiles = (root["profiles"] as? [[String: Any]] ?? []).compactMap { entry -> SettingsProfile? in
      guard let name = entry["name"] as? String, !name.isEmpty else { return nil }
      let areas = (entry["areas"] as? [String: Any] ?? [:]).compactMapValues { data($0).map { String(decoding: $0, as: UTF8.self) } }
      return SettingsProfile(name: name, areas: areas)
    }
    return Setup(areas: areas, profiles: profiles, activeProfile: root["activeProfile"] as? String)
  }
}

extension SettingsStore {
  /// The whole setup as versioned JSON: kept values (not this session's unkept tweaks), profiles.
  func exportJSON() -> Data {
    saveActiveProfile()
    let areas = keptState().mapValues { Data($0.utf8) }
    return SettingsTransfer.json(areas: areas, profiles: profiles, activeProfile: activeProfile)
  }

  /// The share code for the whole setup.
  func exportCode() -> String {
    SettingsTransfer.code(fromJSON: exportJSON())
  }

  /// Applies a pasted code or JSON. Returns what to say. One undoable step.
  func importSetup(_ text: String) -> String {
    if isLocked { return SettingsLines.locked }
    let setup: SettingsTransfer.Setup
    do {
      setup = try SettingsTransfer.parse(text)
    } catch SettingsTransfer.ImportError.newerSchema {
      return "That setup is from a newer version of SpeakUp. Update the app, then try again."
    } catch {
      return "That isn't a SpeakUp setup code. Nothing changed."
    }
    group("imported setup", touchesProfiles: true) {
      for area in areas() {
        guard let data = setup.areas[type(of: area).areaID] else { continue }
        try? area.restore(data)
      }
      for profile in setup.profiles {
        if let index = profiles.firstIndex(where: { $0.name.caseInsensitiveCompare(profile.name) == .orderedSame }) {
          profiles[index] = profile
        } else {
          profiles.append(profile)
        }
      }
      if let active = setup.activeProfile, profiles.contains(where: { $0.name == active }) { activeProfile = active }
      saveProfiles()
    }
    return "Setup imported. Now \(shortSummary()). Say undo to put yours back."
  }
}
