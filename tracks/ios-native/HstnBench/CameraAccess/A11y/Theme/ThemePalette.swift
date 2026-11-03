/*
 * ThemePalette - the colours of the chunky style, as plain numbers so they can be tested
 *
 * Bright faces carry dark text: white on a bright green is about 2:1, dark green on it is above 8:1.
 * Each face has a darker lip, which is also its outline, so a control's edge stays visible against
 * the page even though the bright face alone wouldn't reach 3:1 on white.
 *
 * Rules, checked for every variant by ThemePaletteTests: text at least 4.5:1 (7:1 in the Increase
 * Contrast variants), control boundaries and progress fill at least 3:1. The chosen values and
 * ratios are listed in notes/a11y-onboarding.md.
 */

import SwiftUI
import UIKit

/// An opaque sRGB colour that knows its WCAG luminance.
struct ThemeRGB: Equatable, Sendable {
  let hex: UInt32

  init(_ hex: UInt32) { self.hex = hex }

  var red: CGFloat { CGFloat((hex >> 16) & 0xFF) / 255 }
  var green: CGFloat { CGFloat((hex >> 8) & 0xFF) / 255 }
  var blue: CGFloat { CGFloat(hex & 0xFF) / 255 }

  var uiColor: UIColor { UIColor(red: red, green: green, blue: blue, alpha: 1) }

  var relativeLuminance: Double {
    func linear(_ channel: CGFloat) -> Double {
      let value = Double(channel)
      return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
  }

  /// The WCAG contrast ratio, 1 to 21.
  func contrast(with other: ThemeRGB) -> Double {
    let (a, b) = (relativeLuminance, other.relativeLuminance)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
  }
}

/// A button colour family: its face, the lip under it, and the text on it.
struct ToneColors: Equatable, Sendable {
  let face: ThemeRGB
  let lip: ThemeRGB
  let onFace: ThemeRGB

  init(_ face: UInt32, lip: UInt32, on: UInt32) {
    self.face = ThemeRGB(face)
    self.lip = ThemeRGB(lip)
    self.onFace = ThemeRGB(on)
  }
}

enum Tone: CaseIterable, Sendable {
  case green, blue, purple, orange, red
  /// The page's own card colour with an outline: every action that isn't the main one.
  case neutral
}

struct ThemePalette: Equatable, Sendable {
  let name: String
  let page: ThemeRGB
  let surface: ThemeRGB
  let ink: ThemeRGB
  let inkSoft: ThemeRGB
  let stroke: ThemeRGB
  let lockedFace: ThemeRGB
  let lockedStroke: ThemeRGB
  let lockedText: ThemeRGB
  let track: ThemeRGB
  let fill: ThemeRGB
  let green: ToneColors
  let blue: ToneColors
  let purple: ToneColors
  let orange: ToneColors
  let red: ToneColors

  /// Text minimum this variant promises.
  var textMinimum: Double { name.hasSuffix("HighContrast") ? 7 : 4.5 }

  func colors(for tone: Tone) -> ToneColors {
    switch tone {
    case .green: green
    case .blue: blue
    case .purple: purple
    case .orange: orange
    case .red: red
    case .neutral: ToneColors(surface.hex, lip: stroke.hex, on: ink.hex)
    }
  }

  static let light = ThemePalette(
    name: "light", page: ThemeRGB(0xFFFFFF), surface: ThemeRGB(0xF3F8EF), ink: ThemeRGB(0x13261B), inkSoft: ThemeRGB(0x3A4D42),
    stroke: ThemeRGB(0x6B7F74), lockedFace: ThemeRGB(0xE6ECE2), lockedStroke: ThemeRGB(0x6B7F74), lockedText: ThemeRGB(0x34463B),
    track: ThemeRGB(0xDCE5D6), fill: ThemeRGB(0x2C8A0A),
    green: ToneColors(0x63D420, lip: 0x2E7D0C, on: 0x0B2200),
    blue: ToneColors(0x45C4F8, lip: 0x0B6E9E, on: 0x042436),
    purple: ToneColors(0xD2A3FF, lip: 0x7A3FC0, on: 0x2A0B4D),
    orange: ToneColors(0xFFB429, lip: 0xA85E00, on: 0x3A1E00),
    red: ToneColors(0xFF8F85, lip: 0xB3261E, on: 0x3D0500))

  static let dark = ThemePalette(
    name: "dark", page: ThemeRGB(0x101C24), surface: ThemeRGB(0x1B2B35), ink: ThemeRGB(0xF3F8F4), inkSoft: ThemeRGB(0xC8D5CE),
    stroke: ThemeRGB(0x8496A0), lockedFace: ThemeRGB(0x26363F), lockedStroke: ThemeRGB(0x8FA1AB), lockedText: ThemeRGB(0xD4DFD9),
    track: ThemeRGB(0x2F414C), fill: ThemeRGB(0x7BE241),
    green: ToneColors(0x7BE241, lip: 0x46A812, on: 0x0B2200),
    blue: ToneColors(0x5CCEFA, lip: 0x2A93C6, on: 0x042436),
    purple: ToneColors(0xD6ACFF, lip: 0x9A6BE0, on: 0x2A0B4D),
    orange: ToneColors(0xFFBE55, lip: 0xC8831C, on: 0x3A1E00),
    red: ToneColors(0xFF9C92, lip: 0xD4544A, on: 0x3D0500))

  static let lightHighContrast = ThemePalette(
    name: "lightHighContrast", page: ThemeRGB(0xFFFFFF), surface: ThemeRGB(0xFFFFFF), ink: ThemeRGB(0x000000), inkSoft: ThemeRGB(0x16261C),
    stroke: ThemeRGB(0x22332A), lockedFace: ThemeRGB(0xE6ECE2), lockedStroke: ThemeRGB(0x22332A), lockedText: ThemeRGB(0x16261C),
    track: ThemeRGB(0xDCE5D6), fill: ThemeRGB(0x1B5E00),
    green: ToneColors(0x63D420, lip: 0x1B5200, on: 0x041200),
    blue: ToneColors(0x45C4F8, lip: 0x06445F, on: 0x021420),
    purple: ToneColors(0xD9B3FF, lip: 0x4F2196, on: 0x1A0533),
    orange: ToneColors(0xFFB429, lip: 0x6B3B00, on: 0x241200),
    red: ToneColors(0xFF9F96, lip: 0x7D1610, on: 0x2A0300))

  static let darkHighContrast = ThemePalette(
    name: "darkHighContrast", page: ThemeRGB(0x000000), surface: ThemeRGB(0x0E171D), ink: ThemeRGB(0xFFFFFF), inkSoft: ThemeRGB(0xE4ECE7),
    stroke: ThemeRGB(0xC7D4DB), lockedFace: ThemeRGB(0x1A262D), lockedStroke: ThemeRGB(0xC7D4DB), lockedText: ThemeRGB(0xEEF3F0),
    track: ThemeRGB(0x26343C), fill: ThemeRGB(0x8CF050),
    green: ToneColors(0x8CF050, lip: 0x68C42E, on: 0x041200),
    blue: ToneColors(0x74D8FF, lip: 0x46B2E2, on: 0x021420),
    purple: ToneColors(0xDFBDFF, lip: 0xB48CF0, on: 0x1A0533),
    orange: ToneColors(0xFFC96B, lip: 0xE09C34, on: 0x241200),
    red: ToneColors(0xFFADA5, lip: 0xF07A70, on: 0x2A0300))

  static let all = [light, dark, lightHighContrast, darkHighContrast]

  static func variant(dark isDark: Bool, highContrast: Bool) -> ThemePalette {
    switch (isDark, highContrast) {
    case (false, false): light
    case (true, false): dark
    case (false, true): lightHighContrast
    case (true, true): darkHighContrast
    }
  }

  static func variant(for traits: UITraitCollection) -> ThemePalette {
    let high = traits.accessibilityContrast == .high || LaunchOptions.forcesHighContrast
    return variant(dark: traits.userInterfaceStyle == .dark, highContrast: high)
  }
}

/// The palette as dynamic colours: they follow dark mode and Increase Contrast by themselves.
enum Theme {
  static func dynamic(_ pick: @escaping @Sendable (ThemePalette) -> ThemeRGB) -> Color {
    Color(uiColor: UIColor { traits in pick(ThemePalette.variant(for: traits)).uiColor })
  }

  static let page = dynamic { $0.page }
  static let surface = dynamic { $0.surface }
  static let ink = dynamic { $0.ink }
  static let inkSoft = dynamic { $0.inkSoft }
  static let stroke = dynamic { $0.stroke }
  static let lockedFace = dynamic { $0.lockedFace }
  static let lockedStroke = dynamic { $0.lockedStroke }
  static let lockedText = dynamic { $0.lockedText }
  static let track = dynamic { $0.track }
  static let fill = dynamic { $0.fill }

  static func face(_ tone: Tone) -> Color { dynamic { $0.colors(for: tone).face } }
  static func lip(_ tone: Tone) -> Color { dynamic { $0.colors(for: tone).lip } }
  static func onFace(_ tone: Tone) -> Color { dynamic { $0.colors(for: tone).onFace } }

  static let cardRadius: CGFloat = 24
  static let buttonRadius: CGFloat = 20
}

extension Font {
  /// SF Rounded at a Dynamic Type style, so it scales and follows Bold Text.
  static func rounded(_ style: Font.TextStyle, weight: Font.Weight = .bold) -> Font {
    .system(style, design: .rounded, weight: weight)
  }
}
