/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// MainAppView.swift
//
// Central navigation hub that displays different views based on DAT SDK registration state.
// When unregistered, shows the registration flow. When registered, shows the main reading screen.
//
// HstnBench: until onboarding is completed, its one screen (OnboardingView) comes first. It
// connects the glasses itself, or chooses the iPhone's camera; either way a first run goes from
// there straight to the main screen. HomeScreenView (connect) shows only when the camera setting
// is "glasses" and they aren't linked (CameraSourcePolicy.showsCameraScreen). Resetting it (A11yPreferences.shared.resetOnboarding()) shows it again,
// which is how "Replay setup" works. UI tests skip it unless launched with --onboarding.
//
// The glasses come in as a GlassesLink: WearablesViewModel in the Beta build, NoGlassesLink in the
// App Store build, which never shows the connect screen.
//

import SwiftUI

struct MainAppView: View {
  var link: any GlassesLink

  private let preferences = A11yPreferences.shared

  var body: some View {
    Group {
      if !preferences.onboardingCompleted, !LaunchOptions.skipsOnboarding {
        OnboardingView(link: link)
      } else if !link.supportsGlasses
        || CameraSourcePolicy.showsCameraScreen(CameraSourceRouter.shared.preference, registered: link.isRegistered)
      {
        // Linked glasses, or the phone camera (V0 "Glasses optional": no glasses needed).
        CameraView(link: link)
      } else {
        // The user asked for the glasses and they aren't linked yet: the connect screen.
        HomeScreenView(link: link)
      }
    }
    .safeAreaInset(edge: .top, spacing: 0) { VoiceDownloadNoticeBanner() }
    .onAppear {
      applyFirstRunMode()
      VoiceControl.shared.begin()
      VoiceCoach.shared.begin()
    }
    // What a glasses display may show depends on both.
    .onChange(of: preferences.handsFree) { _, _ in HandsFreeSurface.shared.refresh() }
    .onChange(of: preferences.glassesDisplayEnabled) { _, _ in HandsFreeSurface.shared.refresh() }
    // After setup, and behind the first status line: say once how to get a British voice. The
    // toolbox only shows it.
    .task(id: preferences.onboardingCompleted) {
      guard preferences.onboardingCompleted else { return }
      try? await Task.sleep(for: .seconds(4))
      guard !Task.isCancelled else { return }
      AppVoice.shared.offerDownloadIfNeeded(speak: preferences.handsFree)
    }
    .preferredColorScheme(LaunchOptions.forcesDarkMode ? .dark : nil)
    #if DEBUG
    // An inset, not an overlay: it must not sit on top of a page's pinned buttons.
    .safeAreaInset(edge: .bottom, spacing: 0) { VoiceInjectionOverlay() }
    #endif
  }

  /// The first run with VoiceOver running starts in hands-free and says so once
  /// (notes/hands-free-mode.md section 1). Otherwise the toolbox. UI tests choose with --hands-free.
  private func applyFirstRunMode() {
    if LaunchOptions.isUITesting {
      preferences.handsFree = LaunchOptions.startsHandsFree
      return
    }
    guard !LaunchOptions.isAutomatedTest,
      let on = HandsFreeMode.firstRunChoice(
        hasChoice: preferences.hasHandsFreeChoice, voiceOverRunning: UIAccessibility.isVoiceOverRunning)
    else { return }
    preferences.handsFree = on
    guard on else { return }
    preferences.voiceControlIntroHeard = true
    Announcer.shared.announce(SpokenMessage.handsFreeOnForVoiceOver, earcon: .listening, interrupt: false)
  }
}

/// Launch arguments that change the first-run flow.
enum LaunchOptions {
  /// The benchmark and UI tests launch with --ui-testing and expect the home screen straight away.
  /// Adding --onboarding shows the first-run screen instead (see CameraAccessApp).
  static let isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")
  static let forcesOnboarding = ProcessInfo.processInfo.arguments.contains("--onboarding")
  static let skipsOnboarding = isUITesting && !forcesOnboarding
  /// UI tests, or unit tests hosted in this app. Nothing may prompt or open the mic (VoiceControl),
  /// and one-time spoken notices stay quiet.
  static let isAutomatedTest = isUITesting || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
  /// With --ui-testing: shows a field that feeds transcripts to VoiceControl (see
  /// VoiceInjectionOverlay), so UI tests can drive commands with no mic.
  static let injectsVoice = isUITesting && ProcessInfo.processInfo.arguments.contains("--voice-inject")
  /// With --ui-testing: dark mode, for the tour and audits. XCUIDevice.appearance reported success on
  /// this Simulator (Xcode 27.2) but left the screens light. Otherwise the app follows the system.
  static let forcesDarkMode = isUITesting && ProcessInfo.processInfo.arguments.contains("--dark-mode")
  /// With --ui-testing, for the screenshot tour: draws the Increase Contrast palette without changing
  /// the Simulator's settings.
  static let forcesHighContrast = isUITesting && ProcessInfo.processInfo.arguments.contains("--high-contrast")
  /// With --ui-testing, for the screenshot tour: shows "Listening" and the "Say ..." hints, which a
  /// UI test otherwise can't, since nothing listens. Display only: VoiceControl is unaffected.
  static let previewsListening = isUITesting && ProcessInfo.processInfo.arguments.contains("--preview-listening")
  /// With --ui-testing: start in hands-free mode instead of the toolbox. Nothing listens either way.
  static let startsHandsFree = isUITesting && ProcessInfo.processInfo.arguments.contains("--hands-free")
  /// With --ui-testing: the camera source follows the setting (auto: the phone until glasses are
  /// linked). Without it, UI tests keep the glasses-only screens they were written for
  /// (CameraSourceRouter.preference).
  static let usesPhoneCamera = isUITesting && ProcessInfo.processInfo.arguments.contains("--phone-camera")
}
