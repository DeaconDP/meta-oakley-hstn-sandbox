/*
 * PhoneReadingSettings - choices for reading with the iPhone: framing haptics and the big-text
 * mirror's look. Kept apart from A11yPreferences so Read owns them; the same UserDefaults.
 *
 * ReadingHapticsRow is the one settings row (in the Reading part of Settings).
 */

import Observation
import SwiftUI

@MainActor
@Observable
final class PhoneReadingSettings {
  static let shared = PhoneReadingSettings()

  private enum Key {
    static let haptics = "read.framingHaptics"
    static let mirrorContrast = "read.mirrorContrast"
    static let mirrorScale = "read.mirrorScaleStep"
  }

  @ObservationIgnored private let defaults: UserDefaults

  /// Light taps while lining up a page. On by default. iOS also skips them when System Haptics is
  /// off in Settings > Sounds & Haptics.
  var hapticsEnabled: Bool {
    didSet { defaults.set(hapticsEnabled, forKey: Key.haptics) }
  }

  var mirrorContrast: MirrorContrast {
    didSet { defaults.set(mirrorContrast.rawValue, forKey: Key.mirrorContrast) }
  }

  /// Index into MirrorTextScale.steps.
  var mirrorScaleStep: Int {
    didSet { defaults.set(mirrorScaleStep, forKey: Key.mirrorScale) }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    hapticsEnabled = defaults.object(forKey: Key.haptics) as? Bool ?? true
    mirrorContrast = defaults.string(forKey: Key.mirrorContrast).flatMap(MirrorContrast.init(rawValue:)) ?? .yellowOnBlack
    mirrorScaleStep = MirrorTextScale.clamp(defaults.object(forKey: Key.mirrorScale) as? Int ?? MirrorTextScale.defaultStep)
  }
}

/// "Haptics while lining up a page", in Settings > Reading.
struct ReadingHapticsRow: View {
  @Bindable private var settings = PhoneReadingSettings.shared

  var body: some View {
    Toggle(isOn: $settings.hapticsEnabled) {
      Text("Haptics while lining up a page")
        .font(.rounded(.body, weight: .bold))
        .foregroundStyle(Theme.ink)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(minHeight: 60)
    .accessibilityHint("Light taps when text is cut off, too close or too far, and a steady tap when the page is lined up.")
    .accessibilityIdentifier("reading_haptics_toggle")
    .onChange(of: settings.hapticsEnabled) { _, isOn in
      Announcer.shared.say(isOn ? SpokenMessage.readHapticsOn : SpokenMessage.readHapticsOff)
    }
  }
}
