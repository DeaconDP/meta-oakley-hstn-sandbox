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
    if !preferences.onboardingCompleted, !LaunchOptions.skipsOnboarding {
      OnboardingView(wearablesViewModel: viewModel)
    } else if viewModel.registrationState == .registered {
      CameraView(wearables: wearables, wearablesVM: viewModel)
    } else {
      // User not registered - show registration/onboarding flow
      HomeScreenView(viewModel: viewModel)
    }
  }
}

/// Launch arguments that change the first-run flow.
enum LaunchOptions {
  /// The benchmark and UI tests launch with --ui-testing and expect the home screen straight away.
  /// Adding --onboarding runs the guided setup from the start instead (see CameraAccessApp).
  static let isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")
  static let forcesOnboarding = ProcessInfo.processInfo.arguments.contains("--onboarding")
  static let skipsOnboarding = isUITesting && !forcesOnboarding
}
