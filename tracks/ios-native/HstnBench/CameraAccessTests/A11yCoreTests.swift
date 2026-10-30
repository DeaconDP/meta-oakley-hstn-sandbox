/*
 * A11yCoreTests - the shared audio core's data and the launch router, without audio or devices
 *
 * Covers what can be checked off-device: preferences persist (in an isolated defaults suite, so
 * the host app's real settings are untouched), spoken lines stay short, earcons stay under
 * 300 ms with a tutorial line each, and launch actions run at most once.
 */

import AVFoundation
@testable import CameraAccess
import Foundation
// ast-grep-ignore: swift-testing/swift/no-new-xctest
import XCTest

@MainActor
final class A11yPreferencesTests: XCTestCase {
  private var suiteName = ""
  private var defaults = UserDefaults()

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "A11yPreferencesTests.\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
  }

  override func tearDown() async throws {
    defaults.removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  func testDefaultsOnFirstRun() {
    let preferences = A11yPreferences(defaults: defaults)

    XCTAssertEqual(preferences.verbosity, .normal)
    XCTAssertEqual(preferences.speechRate, AVSpeechUtteranceDefaultSpeechRate)
    XCTAssertFalse(preferences.useAppVoice)
    XCTAssertTrue(preferences.earconsEnabled)
    XCTAssertFalse(preferences.onboardingCompleted)
    XCTAssertNil(preferences.onboardingStep)
    XCTAssertFalse(preferences.disclaimerHeard)
  }

  func testValuesRoundTripThroughDefaults() {
    let preferences = A11yPreferences(defaults: defaults)
    preferences.verbosity = .detailed
    preferences.speechRate = 0.42
    preferences.useAppVoice = true
    preferences.earconsEnabled = false
    preferences.onboardingCompleted = true
    preferences.onboardingStep = "speakerTest"
    preferences.disclaimerHeard = true

    // A fresh instance reads only what was persisted.
    let reloaded = A11yPreferences(defaults: defaults)
    XCTAssertEqual(reloaded.verbosity, .detailed)
    XCTAssertEqual(reloaded.speechRate, 0.42, accuracy: 0.0001)
    XCTAssertTrue(reloaded.useAppVoice)
    XCTAssertFalse(reloaded.earconsEnabled)
    XCTAssertTrue(reloaded.onboardingCompleted)
    XCTAssertEqual(reloaded.onboardingStep, "speakerTest")
    XCTAssertTrue(reloaded.disclaimerHeard)
  }

  func testSpeechRateIsClamped() {
    let preferences = A11yPreferences(defaults: defaults)
    preferences.speechRate = 10
    XCTAssertEqual(preferences.speechRate, AVSpeechUtteranceMaximumSpeechRate)
    preferences.speechRate = -1
    XCTAssertEqual(preferences.speechRate, AVSpeechUtteranceMinimumSpeechRate)

    // An out-of-range value already on disk is clamped on load too.
    defaults.set(Float(99), forKey: "a11y.speechRate")
    XCTAssertEqual(A11yPreferences(defaults: defaults).speechRate, AVSpeechUtteranceMaximumSpeechRate)
  }

  func testUnknownVerbosityFallsBackToNormal() {
    defaults.set("chatty", forKey: "a11y.verbosity")
    XCTAssertEqual(A11yPreferences(defaults: defaults).verbosity, .normal)
  }

  func testResetOnboardingKeepsVoiceChoices() {
    let preferences = A11yPreferences(defaults: defaults)
    preferences.verbosity = .short
    preferences.speechRate = 0.6
    preferences.useAppVoice = true
    preferences.earconsEnabled = false
    preferences.onboardingCompleted = true
    preferences.onboardingStep = "permission"
    preferences.disclaimerHeard = true

    preferences.resetOnboarding()

    let reloaded = A11yPreferences(defaults: defaults)
    XCTAssertFalse(reloaded.onboardingCompleted)
    XCTAssertNil(reloaded.onboardingStep)
    XCTAssertFalse(reloaded.disclaimerHeard)
    XCTAssertEqual(reloaded.verbosity, .short)
    XCTAssertEqual(reloaded.speechRate, 0.6, accuracy: 0.0001)
    XCTAssertTrue(reloaded.useAppVoice)
    XCTAssertFalse(reloaded.earconsEnabled)
  }
}

final class SpokenMessageTests: XCTestCase {
  private func wordCount(_ text: String) -> Int {
    text.split(whereSeparator: { $0.isWhitespace }).count
  }

  /// Lines heard on every launch or state change. Short so they don't hold up the user.
  private var statusLines: [String] {
    [
      SpokenMessage.ready,
      SpokenMessage.glassesNotConnected,
      SpokenMessage.glassesRemoved,
      SpokenMessage.glassesFolded,
      SpokenMessage.batteryLow(percent: 10),
      SpokenMessage.connected(deviceName: "Oakley Meta HSTN"),
      SpokenMessage.registrationCancelled,
      SpokenMessage.registrationTimedOut,
      SpokenMessage.unregistered,
      SpokenMessage.cameraPermissionDenied,
      SpokenMessage.glassesAppUpdateRequired,
      SpokenMessage.firmwareUpdateRequired(deviceName: "Oakley Meta HSTN"),
      SpokenMessage.speakerTestQuestion,
      SpokenMessage.launchLooking,
      SpokenMessage.launchOpeningForStatus,
      SpokenMessage.launchNothingToRepeat,
    ]
  }

  /// Heard once, during onboarding. Longer is fine, but still one breath or two.
  private var onboardingLines: [String] {
    [
      SpokenMessage.welcome,
      SpokenMessage.beforeMetaAIHandoff,
      SpokenMessage.disclaimer,
      SpokenMessage.privacy,
      SpokenMessage.cameraPermissionNeeded,
    ]
  }

  func testStatusLinesAreShort() {
    for line in statusLines {
      XCTAssertFalse(line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      XCTAssertLessThan(wordCount(line), 20, "Too long for a status line: \(line)")
    }
  }

  func testOnboardingLinesAreBounded() {
    for line in onboardingLines {
      XCTAssertFalse(line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      XCTAssertLessThan(wordCount(line), 45, "Too long to follow by ear: \(line)")
    }
  }

  func testLinesEndAsSentences() {
    // Ending punctuation gives a natural pause before whatever is spoken next.
    for line in statusLines + onboardingLines {
      XCTAssertTrue([".", "?", "!"].contains(line.last.map(String.init) ?? ""), "No ending punctuation: \(line)")
    }
  }

  func testNoVagueFailureWording() {
    // notes/a11y-onboarding.md: never "something went wrong" without a cause.
    for line in statusLines + onboardingLines {
      XCTAssertFalse(line.lowercased().contains("something went wrong"), line)
    }
  }
}

final class EarconTests: XCTestCase {
  func testEarconsAreShort() {
    for earcon in Earcon.allCases {
      XCTAssertFalse(earcon.notes.isEmpty, "\(earcon) has no notes")
      XCTAssertGreaterThan(earcon.duration, 0, "\(earcon)")
      XCTAssertLessThan(earcon.duration, 0.3, "\(earcon) is \(earcon.duration) s")
    }
  }

  func testEveryEarconHasAMeaning() {
    for earcon in Earcon.allCases {
      XCTAssertFalse(earcon.spokenMeaning.isEmpty, "\(earcon)")
    }
    // Distinct meanings, so the "learn the sounds" tutorial never says the same thing twice.
    XCTAssertEqual(Set(Earcon.allCases.map(\.spokenMeaning)).count, Earcon.allCases.count)
  }

  func testEarconsRender() throws {
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
    for earcon in Earcon.allCases {
      let buffer = try XCTUnwrap(EarconSynth.render(earcon.notes, timbre: earcon.timbre, format: format), "\(earcon)")
      XCTAssertEqual(Double(buffer.frameLength) / format.sampleRate, earcon.duration, accuracy: 0.01, "\(earcon)")
    }
  }
}

@MainActor
final class LaunchActionRouterTests: XCTestCase {
  func testStartsEmpty() {
    let router = LaunchActionRouter()
    XCTAssertNil(router.pending)
    XCTAssertNil(router.consume())
  }

  func testConsumeReturnsOnce() {
    let router = LaunchActionRouter()
    router.request(.look)
    XCTAssertEqual(router.pending, .look)
    XCTAssertEqual(router.consume(), .look)
    XCTAssertNil(router.pending)
    XCTAssertNil(router.consume())
  }

  func testLatestRequestWins() {
    let router = LaunchActionRouter()
    router.request(.look)
    router.request(.status)
    XCTAssertEqual(router.consume(), .status)
    XCTAssertNil(router.consume())
  }

  func testExpiredRequestIsDropped() {
    var clock = Date(timeIntervalSince1970: 1_000)
    let router = LaunchActionRouter(maxAge: 60, now: { clock })
    router.request(.look)
    clock.addTimeInterval(61)
    XCTAssertNil(router.consume())
    XCTAssertNil(router.pending, "An expired request is still cleared")
  }

  func testRequestWithinMaxAgeRuns() {
    var clock = Date(timeIntervalSince1970: 1_000)
    let router = LaunchActionRouter(maxAge: 60, now: { clock })
    router.request(.repeatLast)
    clock.addTimeInterval(59)
    XCTAssertEqual(router.consume(), .repeatLast)
  }

  func testRawValuesAreStable() {
    // Raw values may end up in URLs or logs; renaming a case shouldn't silently change them.
    XCTAssertEqual(LaunchAction.look.rawValue, "look")
    XCTAssertEqual(LaunchAction.status.rawValue, "status")
    XCTAssertEqual(LaunchAction.repeatLast.rawValue, "repeatLast")
  }

  func testIntentsOpenTheAppOnlyWhenNeeded() {
    // Look needs a foreground stream; Status and Repeat answer through Siri, so work locked.
    XCTAssertTrue(LookIntent.openAppWhenRun)
    XCTAssertFalse(StatusIntent.openAppWhenRun)
    XCTAssertFalse(RepeatLastIntent.openAppWhenRun)
  }
}
