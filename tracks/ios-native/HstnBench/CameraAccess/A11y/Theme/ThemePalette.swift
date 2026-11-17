/*
 * ThemePalette - SpeakUp's colours in the chunky style, as plain numbers so they can be tested
 *
 * Bright faces carry dark text: white on Signal Yellow is about 1.5:1, Night on it is 13.8:1.
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
  /// Signal Yellow, the one main action on a screen.
  case yellow
  /// Success and "connected" marks.
  case green
  /// Listen Cyan family.
  case blue
  case purple, orange
  /// Voice Coral family: stop, warnings.
  case red
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
  /// The voice indicator while the app is listening (Listen Cyan) and while it talks (Voice Coral).
  /// Marks, not text: at least 3:1 on the page and on cards.
  let listen: ThemeRGB
  let speak: ThemeRGB
  /// The main action: Signal Yellow.
  let yellow: ToneColors
  let green: ToneColors
  let blue: ToneColors
  let purple: ToneColors
  let orange: ToneColors
  let red: ToneColors

  /// Text minimum this variant promises.
  var textMinimum: Double { name.hasSuffix("HighContrast") ? 7 : 4.5 }

  func colors(for tone: Tone) -> ToneColors {
    switch tone {
    case .yellow: yellow
    case .green: green
    case .blue: blue
    case .purple: purple
    case .orange: orange
    case .red: red
    case .neutral: ToneColors(surface.hex, lip: stroke.hex, on: ink.hex)
    }
  }

  // SpeakUp brand: Night #0B0B1A, Dusk #1E1A3D, Dusk Line #3A3470, Signal Yellow #FFD60A,
  // Paper #FFF8E7, Voice Coral #FF6B5B (speaking, warnings), Listen Cyan #3DD9EB (listening).
  // Light mode puts Night ink on Paper; dark mode puts Paper ink on Night and Dusk. The outline
  // (`stroke`) is the brand's: Night in light, Paper in dark (tokens.json role.*.outline). Bright faces
  // keep their brand value in both and carry Night text; their lips and the listen/speak colours
  // go darker in light mode, where the bright value alone wouldn't reach 3:1 on Paper.

  static let light = ThemePalette(
    name: "light", page: ThemeRGB(0xFFF8E7), surface: ThemeRGB(0xFFFFFF), ink: ThemeRGB(0x0B0B1A), inkSoft: ThemeRGB(0x37325C),
    stroke: ThemeRGB(0x0B0B1A), lockedFace: ThemeRGB(0xEEEAF6), lockedStroke: ThemeRGB(0x6F6896), lockedText: ThemeRGB(0x37325C),
    track: ThemeRGB(0xE6E1F0), fill: ThemeRGB(0x8A6400), listen: ThemeRGB(0x00727F), speak: ThemeRGB(0xC0392B),
    yellow: ToneColors(0xFFD60A, lip: 0x8A6400, on: 0x0B0B1A),
    green: ToneColors(0x63D420, lip: 0x2E7D0C, on: 0x0B2200),
    blue: ToneColors(0x3DD9EB, lip: 0x00727F, on: 0x0B0B1A),
    purple: ToneColors(0xC9B8FF, lip: 0x5E4DB2, on: 0x1E1A3D),
    orange: ToneColors(0xFFB429, lip: 0xA35A00, on: 0x3A1E00),
    red: ToneColors(0xFF6B5B, lip: 0xB02A1E, on: 0x0B0B1A))

  static let dark = ThemePalette(
    name: "dark", page: ThemeRGB(0x0B0B1A), surface: ThemeRGB(0x1E1A3D), ink: ThemeRGB(0xFFF8E7), inkSoft: ThemeRGB(0xD6D0EE),
    stroke: ThemeRGB(0xFFF8E7), lockedFace: ThemeRGB(0x2A2550), lockedStroke: ThemeRGB(0x948CD4), lockedText: ThemeRGB(0xE2DDF5),
    track: ThemeRGB(0x3A3470), fill: ThemeRGB(0xFFD60A), listen: ThemeRGB(0x3DD9EB), speak: ThemeRGB(0xFF6B5B),
    yellow: ToneColors(0xFFD60A, lip: 0xB89400, on: 0x0B0B1A),
    green: ToneColors(0x7BE241, lip: 0x46A812, on: 0x0B2200),
    blue: ToneColors(0x3DD9EB, lip: 0x1E9DAD, on: 0x0B0B1A),
    purple: ToneColors(0xC9B8FF, lip: 0x8F7BEA, on: 0x1E1A3D),
    orange: ToneColors(0xFFBE55, lip: 0xC8831C, on: 0x3A1E00),
    red: ToneColors(0xFF6B5B, lip: 0xD9483A, on: 0x0B0B1A))

  static let lightHighContrast = ThemePalette(
    name: "lightHighContrast", page: ThemeRGB(0xFFFFFF), surface: ThemeRGB(0xFFFFFF), ink: ThemeRGB(0x000000), inkSoft: ThemeRGB(0x1E1A3D),
    stroke: ThemeRGB(0x000000), lockedFace: ThemeRGB(0xEEEAF6), lockedStroke: ThemeRGB(0x2A2550), lockedText: ThemeRGB(0x1E1A3D),
    track: ThemeRGB(0xE6E1F0), fill: ThemeRGB(0x5C4200), listen: ThemeRGB(0x004E57), speak: ThemeRGB(0x8A1C12),
    yellow: ToneColors(0xFFD60A, lip: 0x5C4200, on: 0x000000),
    green: ToneColors(0x63D420, lip: 0x1B5200, on: 0x041200),
    blue: ToneColors(0x3DD9EB, lip: 0x004E57, on: 0x000000),
    purple: ToneColors(0xD3C6FF, lip: 0x3F2F8F, on: 0x0B0B1A),
    orange: ToneColors(0xFFB429, lip: 0x6B3B00, on: 0x241200),
    red: ToneColors(0xFF8A7D, lip: 0x8A1C12, on: 0x000000))

  static let darkHighContrast = ThemePalette(
    name: "darkHighContrast", page: ThemeRGB(0x000000), surface: ThemeRGB(0x0B0B1A), ink: ThemeRGB(0xFFFFFF), inkSoft: ThemeRGB(0xF0ECFF),
    stroke: ThemeRGB(0xFFFFFF), lockedFace: ThemeRGB(0x1E1A3D), lockedStroke: ThemeRGB(0xC4BEEB), lockedText: ThemeRGB(0xF4F1FF),
    track: ThemeRGB(0x2A2550), fill: ThemeRGB(0xFFE14D), listen: ThemeRGB(0x6FE6F3), speak: ThemeRGB(0xFF8A7D),
    yellow: ToneColors(0xFFE14D, lip: 0xE0B800, on: 0x000000),
    green: ToneColors(0x8CF050, lip: 0x68C42E, on: 0x041200),
    blue: ToneColors(0x6FE6F3, lip: 0x3DC4D4, on: 0x000000),
    purple: ToneColors(0xD9CCFF, lip: 0xA896F0, on: 0x0B0B1A),
    orange: ToneColors(0xFFC96B, lip: 0xE09C34, on: 0x241200),
    red: ToneColors(0xFF8A7D, lip: 0xF0685A, on: 0x000000))

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
  static let listen = dynamic { $0.listen }
  static let speak = dynamic { $0.speak }

  static func face(_ tone: Tone) -> Color { dynamic { $0.colors(for: tone).face } }
  static func lip(_ tone: Tone) -> Color { dynamic { $0.colors(for: tone).lip } }
  static func onFace(_ tone: Tone) -> Color { dynamic { $0.colors(for: tone).onFace } }

  /// The mascot's sticker outline around props drawn in Night ink outside its body: Paper on dark
  /// pages, where Night ink would vanish; the page colour on light ones, where it doesn't show.
  static let mascotOutline = dynamic { $0.isDark ? $0.ink : $0.page }

  /// The voice ribbon's colour for each state (tokens.json `state`). Yellow, Cyan and Coral are the
  /// brand values on dark pages; on light pages they use the darker partners that reach 3:1 on Paper.
  static func ribbon(_ state: RibbonState) -> Color {
    switch state {
    case .idle: dynamic { $0.isDark ? $0.yellow.face : $0.yellow.lip }
    case .listening: listen
    case .thinking: ink
    case .speaking, .error: speak
    }
  }

  // MARK: Layout tokens (tokens.json `space`, `radius`, `size`)

  enum Space {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48
  }

  enum Radius {
    static let sm: CGFloat = 8
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
    /// Clamped by the shape to half its height: a capsule.
    static let pill: CGFloat = 999
  }

  static let cardRadius: CGFloat = Radius.lg
  static let buttonRadius: CGFloat = Radius.md
  /// The one main action on a screen.
  static let primaryButtonHeight: CGFloat = 72
  static let touchTargetMin: CGFloat = 56
  static let outlineWidth: CGFloat = 2
  static let outlineWidthIncreased: CGFloat = 3

  /// Readable column width on wide screens.
  static let maxContentWidth: CGFloat = 700

  // MARK: Motion (tokens.json `motion`)

  /// Every state change (a card appearing, the status changing, the mascot's mood): 240 ms on the
  /// brand's cubic-bezier(0.2, 0, 0, 1). Calm, no bounce.
  static let stateChangeAnimation = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.24)

  /// The state-change animation, or none under Reduce Motion: changes then simply cut, and anything
  /// using an opacity transition doesn't move.
  static func stateChange(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : stateChangeAnimation
  }
}

extension ThemePalette {
  var isDark: Bool { name.hasPrefix("dark") }
}

/// Light or dark. The brand is dark-first (tokens.json), so the app is dark unless the user picks
/// light in Settings. UI tests can force either with --dark-mode / --light-mode.
@MainActor
@Observable
final class ThemeAppearance {
  static let shared = ThemeAppearance()

  enum Mode: String, Sendable {
    case dark, light
  }

  @ObservationIgnored private let defaults: UserDefaults
  static let key = "theme.appearance"

  /// The user's choice, kept in UserDefaults. Dark until they choose light.
  var mode: Mode {
    didSet { defaults.set(mode.rawValue, forKey: Self.key) }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    mode = defaults.string(forKey: Self.key).flatMap(Mode.init(rawValue:)) ?? .dark
  }

  /// What the app asks the system for: a test's forced mode first, then the user's choice.
  var colorScheme: ColorScheme {
    if LaunchOptions.forcesDarkMode { return .dark }
    if LaunchOptions.forcesLightMode { return .light }
    return mode == .light ? .light : .dark
  }
}

extension LaunchOptions {
  /// With --ui-testing: light mode, for the tour and audits now that the app starts dark.
  static let forcesLightMode = isUITesting && ProcessInfo.processInfo.arguments.contains("--light-mode")
}

extension View {
  /// Animates changes to `value` with the shared state-change motion, respecting Reduce Motion.
  func stateAnimation<V: Equatable>(value: V) -> some View {
    modifier(StateAnimation(value: value))
  }
}

private struct StateAnimation<V: Equatable>: ViewModifier {
  let value: V
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content.animation(Theme.stateChange(reduceMotion: reduceMotion), value: value)
  }
}

/// SpeakUp's typeface: Atkinson Hyperlegible (Braille Institute, SIL OFL 1.1), bundled from
/// A11y/Theme/Fonts and registered with UIAppFonts. It has Regular and Bold only.
enum BrandFont {
  static let regular = "AtkinsonHyperlegible-Regular"
  static let bold = "AtkinsonHyperlegible-Bold"

  /// The face for a weight: medium and lighter read as Regular, semibold and heavier as Bold.
  /// Bold Text turns everything Bold, as the system font would.
  static func name(for weight: Font.Weight, boldText: Bool = boldTextEnabled) -> String {
    if boldText { return bold }
    switch weight {
    case .ultraLight, .thin, .light, .regular, .medium: return regular
    default: return bold
    }
  }

  /// UIAccessibility is main-actor only; fonts are almost always built in a view body on the main
  /// thread. Elsewhere this reads as off, which only means Regular stays Regular.
  static var boldTextEnabled: Bool {
    Thread.isMainThread ? MainActor.assumeIsolated { UIAccessibility.isBoldTextEnabled } : false
  }

  /// Each Dynamic Type style's size at the default (Large) setting, from the brand scale
  /// (tokens.json `type.scale`): headline 34, title 26, body large 22, body and label 20, caption 18.
  /// Nothing is below 18, and `relativeTo:` scales every one with the user's text size.
  static func baseSize(_ style: Font.TextStyle) -> CGFloat {
    switch style {
    case .largeTitle: 34  // headline
    case .title: 26  // title
    case .title2, .title3: 22  // body large
    case .headline, .body, .callout: 20  // label, body
    case .subheadline, .footnote, .caption, .caption2: 18  // caption, the minimum
    @unknown default: 20
    }
  }
}

extension Font {
  /// The brand face at a Dynamic Type style: it scales with the user's text size up to AX5.
  /// (Named for the SF Rounded it replaced, so every screen picked it up unchanged.)
  static func rounded(_ style: Font.TextStyle, weight: Font.Weight = .bold) -> Font {
    .custom(BrandFont.name(for: weight), size: BrandFont.baseSize(style), relativeTo: style)
  }

  /// The brand face at an exact size that still scales with Dynamic Type like `style`.
  static func brand(size: CGFloat, relativeTo style: Font.TextStyle, weight: Font.Weight = .bold) -> Font {
    .custom(BrandFont.name(for: weight), size: size, relativeTo: style)
  }
}
