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
// connects the glasses itself, so a first run goes from there straight to the main screen; Not now
// lands on HomeScreenView. Resetting it (A11yPreferences.shared.resetOnboarding()) shows it again,
// which is how "Replay setup" works. UI tests skip it unless launched with --onboarding.
//

import MWDATCore
import SwiftUI

struct MainAppView: View {
  let wearables: WearablesInterface
  var viewModel: WearablesViewModel

  private let preferences = A11yPreferences.shared

  var body: some View {
    Group {
      if !preferences.onboardingCompleted, !LaunchOptions.skipsOnboarding {
        OnboardingView(wearablesViewModel: viewModel)
      } else if viewModel.registrationState == .registered {
        CameraView(wearables: wearables, wearablesVM: viewModel)
      } else {
        // User not registered - show registration/onboarding flow
        HomeScreenView(viewModel: viewModel)
      }
    }
    .safeAreaInset(edge: .top, spacing: 0) { VoiceDownloadNoticeBanner() }
    .onAppear {
      VoiceControl.shared.begin()
      VoiceCoach.shared.begin()
    }
    // After setup, and behind the first status line: say once how to get a British voice.
    .task(id: preferences.onboardingCompleted) {
      guard preferences.onboardingCompleted else { return }
      try? await Task.sleep(for: .seconds(4))
      guard !Task.isCancelled else { return }
      AppVoice.shared.offerDownloadIfNeeded()
    }
    // Dark-first: dark unless the user chose light in Settings (ThemeAppearance).
    .preferredColorScheme(ThemeAppearance.shared.colorScheme)
    #if DEBUG
    // An inset, not an overlay: it must not sit on top of a page's pinned buttons.
    .safeAreaInset(edge: .bottom, spacing: 0) { VoiceInjectionOverlay() }
    #endif
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
  /// this Simulator (Xcode 27.2) but left the screens light. Otherwise the app is dark unless the
  /// user picked light (ThemeAppearance); --light-mode forces light.
  static let forcesDarkMode = isUITesting && ProcessInfo.processInfo.arguments.contains("--dark-mode")
  /// With --ui-testing, for the screenshot tour: draws the Increase Contrast palette without changing
  /// the Simulator's settings.
  static let forcesHighContrast = isUITesting && ProcessInfo.processInfo.arguments.contains("--high-contrast")
  /// With --ui-testing, for the screenshot tour: shows "Listening" and the "Say ..." hints, which a
  /// UI test otherwise can't, since nothing listens. Display only: VoiceControl is unaffected.
  static let previewsListening = isUITesting && ProcessInfo.processInfo.arguments.contains("--preview-listening")
}
