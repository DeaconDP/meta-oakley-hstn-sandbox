/*
 * EarsArea - "Your ears" in Make it your own (customisation roadmap C2)
 *
 * - balance: -1 (left) to 1 (right) in steps of 20 % ("move it left a bit", "centre the sound").
 * - which ear for which sound: speech, sounds (earcons) and alerts each go to the left, the right
 *   or both ears. A one-ear route wins over the balance (AudioShape.pan).
 * - mono: iOS's Mono Audio setting is read live (UIAccessibility.isMonoAudioEnabled and its change
 *   notification); "I use mono" turns it on in the app too, for glasses or headphones that sum the
 *   channels. With mono, panning is off and left/right cues use pitch (AudioShape.sideCue).
 * - Clear speech: SpeakUp's own voice slower, compressed and with the treble lifted, by an amount
 *   the listening check ("which is clearer, A or B?") can tune. Speech clarity for SpeakUp's voice
 *   only; it doesn't touch any other sound or app.
 *
 * Stored as this area's snapshot JSON under "customise.ears". The OS mono state isn't stored.
 */

import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class EarsArea: SettingsArea {
  static let shared = EarsArea(live: true)

  static let areaID = "ears"
  static let storageKey = "customise.ears"
  nonisolated static let balanceStep: Float = 0.2

  struct Values: Codable, Equatable, Sendable {
    var balance: Float = 0
    var speechRoute: EarRoute = .both
    var earconRoute: EarRoute = .both
    var alertRoute: EarRoute = .both
    var userMono = false
    var clearSpeech = false
    var trebleGainDB: Float = ClearSpeech.defaultTrebleGainDB

    init() {}

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      let standard = Values()
      balance = try container.decodeIfPresent(Float.self, forKey: .balance) ?? standard.balance
      speechRoute = (try? container.decodeIfPresent(EarRoute.self, forKey: .speechRoute)) ?? standard.speechRoute
      earconRoute = (try? container.decodeIfPresent(EarRoute.self, forKey: .earconRoute)) ?? standard.earconRoute
      alertRoute = (try? container.decodeIfPresent(EarRoute.self, forKey: .alertRoute)) ?? standard.alertRoute
      userMono = try container.decodeIfPresent(Bool.self, forKey: .userMono) ?? standard.userMono
      clearSpeech = try container.decodeIfPresent(Bool.self, forKey: .clearSpeech) ?? standard.clearSpeech
      trebleGainDB = try container.decodeIfPresent(Float.self, forKey: .trebleGainDB) ?? standard.trebleGainDB
    }

    func clamped() -> Values {
      var copy = self
      copy.balance = EarsArea.steppedBalance(balance)
      copy.trebleGainDB = min(max(trebleGainDB, ClearSpeech.trebleSteps.first!), ClearSpeech.trebleSteps.last!)
      return copy
    }

    func route(for kind: SoundKind) -> EarRoute {
      switch kind {
      case .speech: speechRoute
      case .earcon: earconRoute
      case .alert: alertRoute
      }
    }

    mutating func setRoute(_ route: EarRoute, for kind: SoundKind) {
      switch kind {
      case .speech: speechRoute = route
      case .earcon: earconRoute = route
      case .alert: alertRoute = route
      }
    }
  }

  var spokenName: String { "your ears" }

  private(set) var values: Values
  /// iOS's Mono Audio setting, kept live.
  private(set) var systemMono: Bool

  /// Mono in effect: the iOS setting or the user's own "I use mono".
  var isMono: Bool { systemMono || values.userMono }

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let live: Bool
  @ObservationIgnored private var monoObserver: NSObjectProtocol?

  init(defaults: UserDefaults = .standard, systemMono: Bool = false) {
    self.defaults = defaults
    live = false
    self.systemMono = systemMono
    values = Self.load(defaults)
  }

  private init(live: Bool) {
    defaults = .standard
    self.live = live
    systemMono = UIAccessibility.isMonoAudioEnabled
    values = Self.load(.standard)
  }

  private static func load(_ defaults: UserDefaults) -> Values {
    (defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(Values.self, from: $0) } ?? Values()).clamped()
  }

  /// Follows iOS's Mono Audio setting, and says so when it changes while the app runs.
  func observeSystemMono() {
    guard live, monoObserver == nil else { return }
    monoObserver = NotificationCenter.default.addObserver(
      forName: UIAccessibility.monoAudioStatusDidChangeNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated {
        let area = EarsArea.shared
        if let line = area.systemMonoChanged(UIAccessibility.isMonoAudioEnabled) {
          Announcer.shared.say(line, interrupt: false)
        }
      }
    }
  }

  /// The line to say about a change in iOS's mono setting, or nil when nothing changed for the user.
  func systemMonoChanged(_ on: Bool) -> String? {
    guard on != systemMono else { return nil }
    let wasMono = isMono
    systemMono = on
    if live { AudioCustomisation.refreshShape() }
    guard wasMono != isMono else { return nil }
    return isMono
      ? "Mono audio is on. I'll mark left and right with a lower or higher tone, and say the side."
      : "Mono audio is off. Left and right sounds come from their side again."
  }

  // MARK: SettingsArea

  func snapshot() -> Data {
    (try? AudioCustomisation.encoder.encode(values)) ?? Data("{}".utf8)
  }

  func restore(_ data: Data) throws {
    set(try JSONDecoder().decode(Values.self, from: data).clamped())
  }

  func resetToDefaults() {
    set(Values())
  }

  func differencesFromDefaults() -> [String] {
    Self.differences(values)
  }

  static func differences(_ values: Values) -> [String] {
    let standard = Values()
    var lines: [String] = []
    if values.balance != standard.balance { lines.append("balance \(balanceWords(values.balance))") }
    for kind in SoundKind.allCases where values.route(for: kind) != .both {
      lines.append("\(kind.spoken) in \(values.route(for: kind).spoken)")
    }
    if values.userMono { lines.append("mono on") }
    if values.clearSpeech {
      lines.append(
        values.trebleGainDB == standard.trebleGainDB
          ? "clear speech on" : "clear speech on, treble \(Int(values.trebleGainDB)) decibels")
    }
    return lines
  }

  // MARK: Changes (each returns the line to speak)

  func moveBalance(steps: Int) -> String {
    let target = Self.steppedBalance(values.balance + Float(steps) * Self.balanceStep)
    let edge = steps < 0 ? "The sound is already all the way left." : "The sound is already all the way right."
    return change(unchanged: edge, { $0.balance = target }, describe: { self.balanceLine($0) })
  }

  func setBalance(_ balance: Float) -> String {
    change(unchanged: "The balance is already there.", { $0.balance = balance }, describe: { self.balanceLine($0) })
  }

  func centreBalance() -> String {
    change(unchanged: "The sound is already in the centre.", { $0.balance = 0 }, describe: { self.balanceLine($0) })
  }

  /// `kinds` empty means every kind ("everything in both ears").
  func setRoute(_ route: EarRoute, for kinds: [SoundKind]) -> String {
    let kinds = kinds.isEmpty ? SoundKind.allCases : kinds
    let name = kinds.count == SoundKind.allCases.count ? "everything" : Self.list(kinds.map(\.spoken))
    let monoNote = isMono && route != .both ? " Mono is on, so you'll hear it in both ears until mono is off." : ""
    return change(
      unchanged: "\(name.prefix(1).uppercased() + name.dropFirst()) is already in \(route.spoken).",
      { values in kinds.forEach { values.setRoute(route, for: $0) } },
      describe: { _ in "\(name.prefix(1).uppercased() + name.dropFirst()) in \(route.spoken).\(monoNote)" })
  }

  func setUserMono(_ on: Bool) -> String {
    change(
      unchanged: on ? "Mono is already on." : "Mono is already off.",
      { $0.userMono = on },
      describe: { values in
        if on { return "Mono on. I'll mark left and right with a lower or higher tone, and say the side." }
        return self.systemMono
          ? "Mono off in SpeakUp, but your iPhone's Mono Audio setting is still on." : "Mono off. Stereo again."
      })
  }

  func setClearSpeech(_ on: Bool) -> String {
    change(
      unchanged: on ? "Clear speech is already on." : "Clear speech is already off.",
      { $0.clearSpeech = on },
      describe: { _ in
        on
          ? "Clear speech on. My voice is a little slower, steadier and brighter. Say check clear speech to tune it."
          : "Clear speech off."
      })
  }

  /// From the listening check: turns Clear speech on at `gain`.
  func setTrebleGain(_ gain: Float) -> String {
    change(
      unchanged: "Clear speech is already set like that.",
      {
        $0.trebleGainDB = gain
        $0.clearSpeech = true
      },
      describe: { "Clear speech set, treble \(Int($0.trebleGainDB)) decibels. Say undo to put it back." })
  }

  // MARK: Helpers

  private func change(unchanged: String, _ mutate: (inout Values) -> Void, describe: (Values) -> String) -> String {
    if SettingsChanges.isLocked() { return AudioCustomisation.lockedMessage }
    var new = values
    mutate(&new)
    new = new.clamped()
    guard new != values else { return unchanged }
    let description = describe(new)
    SettingsChanges.record(Self.areaID, before: snapshot(), description: description)
    set(new)
    return description
  }

  private func set(_ new: Values) {
    values = new
    if let data = try? AudioCustomisation.encoder.encode(new) { defaults.set(data, forKey: Self.storageKey) }
    if live { AudioCustomisation.refreshShape() }
  }

  private func balanceLine(_ values: Values) -> String {
    let base = values.balance == 0 ? "Sound centred." : "Sound \(Self.balanceWords(values.balance))."
    return isMono && values.balance != 0 ? base + " Mono is on, so balance won't change anything until it's off." : base
  }

  nonisolated static func steppedBalance(_ balance: Float) -> Float {
    let stepped = (balance / balanceStep).rounded() * balanceStep
    return min(1, max(-1, (stepped * 100).rounded() / 100))
  }

  /// "40 percent left", "all the way right", "centred".
  nonisolated static func balanceWords(_ balance: Float) -> String {
    if balance == 0 { return "centred" }
    let side = balance < 0 ? "left" : "right"
    let amount = Int((abs(balance) * 100).rounded())
    return amount >= 100 ? "all the way \(side)" : "\(amount) percent \(side)"
  }

  nonisolated static func list(_ items: [String]) -> String {
    guard items.count > 1 else { return items.first ?? "" }
    return items.dropLast().joined(separator: ", ") + " and " + items.last!
  }
}
