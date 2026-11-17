/*
 * ThemeTests - the palette's contrast, the reading progress store and the voice indicator
 *
 * Contrast is computed, never eyeballed: every pair the screens use, in every variant. The progress
 * tests cover the cases that would otherwise only show up on a real calendar: midnight, missed days,
 * month and year ends, daylight saving, and a clock moved backwards.
 */

@testable import CameraAccess
import Foundation
import SwiftUI
import UIKit
// ast-grep-ignore: swift-testing/swift/no-new-xctest
import XCTest

final class ThemePaletteTests: XCTestCase {
  private func assertContrast(
    _ a: ThemeRGB, _ b: ThemeRGB, atLeast minimum: Double, _ what: String, in palette: ThemePalette,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let ratio = a.contrast(with: b)
    XCTAssertGreaterThanOrEqual(ratio, minimum, "\(palette.name) \(what): \(String(format: "%.2f", ratio)):1", file: file, line: line)
  }

  func testKnownRatios() {
    XCTAssertEqual(ThemeRGB(0x000000).contrast(with: ThemeRGB(0xFFFFFF)), 21, accuracy: 0.001)
    XCTAssertEqual(ThemeRGB(0xFFFFFF).contrast(with: ThemeRGB(0xFFFFFF)), 1, accuracy: 0.001)
    // White on Signal Yellow: why the bright faces carry dark text.
    XCTAssertLessThan(ThemeRGB(0xFFFFFF).contrast(with: ThemePalette.light.yellow.face), 3)
  }

  func testSpeakUpBrandColours() {
    // Signal Yellow is the main action's face in the standard variants, with Night text on it.
    for palette in [ThemePalette.light, ThemePalette.dark] {
      XCTAssertEqual(palette.yellow.face, ThemeRGB(0xFFD60A), palette.name)
      XCTAssertEqual(palette.yellow.onFace, ThemeRGB(0x0B0B1A), palette.name)
    }
    XCTAssertEqual(ThemePalette.light.page, ThemeRGB(0xFFF8E7), "Paper")
    XCTAssertEqual(ThemePalette.dark.page, ThemeRGB(0x0B0B1A), "Night")
    XCTAssertEqual(ThemePalette.dark.surface, ThemeRGB(0x1E1A3D), "Dusk")
    XCTAssertEqual(ThemePalette.dark.listen, ThemeRGB(0x3DD9EB), "Listen Cyan")
    XCTAssertEqual(ThemePalette.dark.speak, ThemeRGB(0xFF6B5B), "Voice Coral")
    // tokens.json role.light.outline / role.dark.outline: Night in light, Paper in dark.
    XCTAssertEqual(ThemePalette.light.stroke, ThemeRGB(0x0B0B1A), "Outline is Night in light mode")
    XCTAssertEqual(ThemePalette.dark.stroke, ThemeRGB(0xFFF8E7), "Outline is Paper in dark mode")
  }

  func testTypeScaleFollowsTheBrand() {
    // tokens.json type.scale: body and label 20, caption 18 (the minimum), body large 22.
    XCTAssertEqual(BrandFont.baseSize(.body), 20)
    XCTAssertEqual(BrandFont.baseSize(.headline), 20)
    XCTAssertEqual(BrandFont.baseSize(.callout), 20)
    XCTAssertEqual(BrandFont.baseSize(.title2), 22)
    XCTAssertEqual(BrandFont.baseSize(.title), 26)
    XCTAssertEqual(BrandFont.baseSize(.largeTitle), 34)
    for style in [Font.TextStyle.subheadline, .footnote, .caption, .caption2] {
      XCTAssertEqual(BrandFont.baseSize(style), 18, "Nothing below the 18 pt caption")
    }
  }

  func testLayoutTokensMatchTheBrand() {
    XCTAssertEqual(
      [Theme.Space.xxs, Theme.Space.xs, Theme.Space.sm, Theme.Space.md, Theme.Space.lg, Theme.Space.xl], [4, 8, 12, 16, 24, 32])
    XCTAssertEqual([Theme.Radius.sm, Theme.Radius.md, Theme.Radius.lg, Theme.Radius.xl], [8, 16, 24, 32])
    XCTAssertEqual(Theme.primaryButtonHeight, 72)
  }

  func testRibbonColoursReachThreeToOne() {
    // The ribbon is decoration (the words carry the state) but still meets the non-text minimum.
    for palette in ThemePalette.all {
      let idle = palette.isDark ? palette.yellow.face : palette.yellow.lip
      for background in [palette.page, palette.surface] {
        assertContrast(idle, background, atLeast: 3, "idle ribbon", in: palette)
        assertContrast(palette.ink, background, atLeast: 3, "working ribbon", in: palette)
      }
    }
  }

  func testTextMeetsItsMinimumInEveryVariant() {
    for palette in ThemePalette.all {
      let minimum = palette.textMinimum
      for background in [palette.page, palette.surface] {
        assertContrast(palette.ink, background, atLeast: minimum, "ink", in: palette)
        assertContrast(palette.inkSoft, background, atLeast: minimum, "soft ink", in: palette)
      }
      assertContrast(palette.lockedText, palette.lockedFace, atLeast: minimum, "locked text", in: palette)
      for tone in Tone.allCases {
        let colors = palette.colors(for: tone)
        assertContrast(colors.onFace, colors.face, atLeast: minimum, "text on \(tone)", in: palette)
      }
    }
  }

  func testBoundariesReachThreeToOneInEveryVariant() {
    for palette in ThemePalette.all {
      for background in [palette.page, palette.surface] {
        assertContrast(palette.stroke, background, atLeast: 3, "card outline", in: palette)
        assertContrast(palette.lockedStroke, background, atLeast: 3, "locked outline", in: palette)
        for tone in Tone.allCases where tone != .neutral {
          assertContrast(palette.colors(for: tone).lip, background, atLeast: 3, "\(tone) lip", in: palette)
        }
      }
      for background in [palette.page, palette.surface] {
        assertContrast(palette.listen, background, atLeast: 3, "listening cue", in: palette)
        assertContrast(palette.speak, background, atLeast: 3, "speaking cue", in: palette)
      }
      assertContrast(palette.fill, palette.track, atLeast: 3, "progress fill on its track", in: palette)
      assertContrast(palette.fill, palette.surface, atLeast: 3, "progress fill on its card", in: palette)
    }
  }

  func testBrandFontIsBundledAndRegistered() {
    for name in [BrandFont.regular, BrandFont.bold] {
      XCTAssertNotNil(UIFont(name: name, size: 17), "\(name) isn't registered: check UIAppFonts and the bundle")
    }
    XCTAssertEqual(BrandFont.name(for: .medium, boldText: false), BrandFont.regular)
    XCTAssertEqual(BrandFont.name(for: .heavy, boldText: false), BrandFont.bold)
    XCTAssertEqual(BrandFont.name(for: .regular, boldText: true), BrandFont.bold, "Bold Text makes it bold")
  }

  func testDynamicColoursFollowDarkModeAndIncreaseContrast() {
    let cases: [(UIUserInterfaceStyle, UIAccessibilityContrast, ThemePalette)] = [
      (.light, .normal, .light), (.dark, .normal, .dark), (.light, .high, .lightHighContrast), (.dark, .high, .darkHighContrast),
    ]
    for (style, contrast, expected) in cases {
      let traits = UITraitCollection { traits in
        traits.userInterfaceStyle = style
        traits.accessibilityContrast = contrast
      }
      XCTAssertEqual(ThemePalette.variant(for: traits).name, expected.name)
      let resolved = UIColor(Theme.page).resolvedColor(with: traits)
      var red: CGFloat = 0
      resolved.getRed(&red, green: nil, blue: nil, alpha: nil)
      XCTAssertEqual(red, expected.page.red, accuracy: 0.01, expected.name)
    }
  }
}

@MainActor
final class VoiceIndicatorModelTests: XCTestCase {
  private func model(
    _ status: VoiceControl.Status, reason: String? = nil, listener: VoiceListenerKind? = .phone,
    mic: VoicePermission = .granted, speech: VoicePermission = .granted, speaking: Bool = false, heard: VoiceCommand? = nil,
    canPrompt: Bool = true
  ) -> VoiceIndicatorModel {
    VoiceIndicatorModel.make(
      status: status, reason: reason, listener: listener, micPermission: mic, speechPermission: speech, isSpeaking: speaking,
      heard: heard, canPrompt: canPrompt)
  }

  func testListeningSaysSoInWords() {
    XCTAssertEqual(model(.listening).title, "Listening")
    XCTAssertEqual(model(.listening).mood, .listening)
    XCTAssertEqual(model(.listening, listener: .glasses).title, "Listening through your glasses")
    XCTAssertNil(model(.listening).fix)
  }

  func testWhileTheAppTalksItExplainsTheWakeWord() {
    XCTAssertTrue(model(.listening, speaking: true).detail?.contains("reader") == true)
    XCTAssertTrue(model(.listening, speaking: false).detail?.contains("help") == true)
  }

  func testAHeardCommandIsShownByItsPhrase() {
    XCTAssertTrue(model(.listening, heard: .read).title.contains("read"))
    XCTAssertEqual(model(.listening, heard: .read).mood, .happy)
  }

  func testUnavailableShowsTheReasonAndAFix() {
    let denied = model(.unavailable, reason: SpokenMessage.voicePermissionDenied, mic: .denied)
    XCTAssertEqual(denied.detail, SpokenMessage.voicePermissionDenied)
    XCTAssertEqual(denied.fix, .openSettings)
    XCTAssertEqual(denied.mood, .confused)
    XCTAssertFalse(denied.isCompact, "A long reason scrolls with the page instead of pinning")
    let noDictation = model(.unavailable, reason: SpokenMessage.voiceNoOnDeviceRecognition)
    XCTAssertEqual(noDictation.fix, .openSettings)
    let notAsked = model(.unavailable, reason: "Waiting", mic: .notDetermined)
    XCTAssertEqual(notAsked.fix, .askPermission)
  }

  func testSignalIsCyanWhileListeningAndCoralWhileTalkingOrStuck() {
    XCTAssertEqual(model(.listening).signal, .listening)
    XCTAssertEqual(model(.listening, speaking: true).signal, .speaking)
    XCTAssertEqual(model(.unavailable, reason: "Waiting").signal, .warning)
    XCTAssertEqual(model(.off).signal, .quiet)
    XCTAssertEqual(model(.paused, reason: "Paused by a call or another app.").signal, .quiet)
  }

  func testReaderWorkShowsWorkingNotListening() {
    let working = VoiceIndicatorModel.make(
      status: .listening, reason: nil, listener: .phone, micPermission: .granted, speechPermission: .granted,
      isSpeaking: false, heard: nil, canPrompt: true, isWorking: true, workDetail: "Finding text")
    XCTAssertEqual(working.title, "Working on it")
    XCTAssertEqual(working.detail, "Finding text")
    XCTAssertEqual(working.signal, .working)
    XCTAssertEqual(working.ribbon, .thinking)
  }

  func testRibbonStates() {
    XCTAssertEqual(model(.listening).ribbon, .listening)
    XCTAssertEqual(model(.listening, speaking: true).ribbon, .speaking)
    XCTAssertEqual(model(.unavailable, reason: "Waiting").ribbon, .error)
    XCTAssertEqual(model(.off).ribbon, .idle)
  }

  func testOffOffersTurningItBackOn() {
    XCTAssertEqual(model(.off).fix, .turnOn)
  }

  func testTestsDontOfferAPrompt() {
    XCTAssertNil(model(.unavailable, reason: "Waiting", mic: .notDetermined, canPrompt: false).fix)
  }

  func testPausedGivesTheReason() {
    let paused = model(.paused, reason: "Paused by a call or another app.")
    XCTAssertEqual(paused.title, "Listening paused")
    XCTAssertEqual(paused.spokenLabel, "Listening paused. Paused by a call or another app.")
  }
}
