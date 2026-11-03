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
// Central navigation hub that displays different views based on DAT SDK registration and device states.
// When unregistered, shows the registration flow. When registered, shows the device selection screen
// for choosing which Meta wearable device to stream from.
//
// HstnBench: until onboarding is completed (or skipped), the guided setup comes first, before
// registration. Resetting it (A11yPreferences.shared.resetOnboarding()) shows it again, which is
// how "Replay setup" works. UI tests skip it unless launched with --onboarding.
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
    .onAppear { VoiceControl.shared.begin() }
    // After setup, and behind the first status line: say once how to get a British voice.
    .task(id: preferences.onboardingCompleted) {
      guard preferences.onboardingCompleted else { return }
      try? await Task.sleep(for: .seconds(4))
      guard !Task.isCancelled else { return }
      AppVoice.shared.offerDownloadIfNeeded()
    }
    // On top of everything, ignoring touches and hidden from VoiceOver.
    .overlay { CelebrationOverlay() }
    .preferredColorScheme(LaunchOptions.forcesDarkMode ? .dark : nil)
    #if DEBUG
    // An inset, not an overlay: it must not sit on top of a page's pinned buttons.
    .safeAreaInset(edge: .bottom, spacing: 0) { VoiceInjectionOverlay() }
    #endif
  }
}

/// Launch arguments that change the first-run flow.
enum LaunchOptions {
  /// The benchmark and UI tests launch with --ui-testing and expect the home screen straight away.
  /// Adding --onboarding runs the guided setup from the start instead (see CameraAccessApp).
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
  /// With --ui-testing: --progress-seed=streak,pages starts ReadingProgressStore there.
  static let progressSeed: (streak: Int, pages: Int)? = {
    guard isUITesting,
      let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--progress-seed=") })
    else { return nil }
    let numbers = argument.dropFirst("--progress-seed=".count).split(separator: ",").compactMap { Int($0) }
    return numbers.count == 2 ? (numbers[0], numbers[1]) : nil
  }()
}
