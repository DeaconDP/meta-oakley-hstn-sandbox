/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// CameraAccessApp.swift
//
// Main entry point for the CameraAccess sample app demonstrating the Meta Wearables DAT SDK.
// This app shows how to connect to wearable devices (like Ray-Ban Meta smart glasses),
// stream live video from their cameras, and capture photos. It provides a complete example
// of DAT SDK integration including device registration, permissions, and media streaming.
//
// HstnBench: errors get a specific title, a spoken sentence with an earcon (WearablesViewModel
// .present), and one action where there is one, instead of a generic "Something went wrong".
//

import Foundation
import MWDATCore
import SwiftUI

#if DEBUG
import MWDATMockDevice
#endif

@main
struct CameraAccessApp: App {
  #if DEBUG
  // Debug menu for simulating device connections during development. The
  // ladybug button toggles `showDebugMenu`; the sheet hosts the mock device kit.
  @State private var showDebugMenu = false
  @State private var mockDeviceKitViewModel = MockDeviceKitViewModel(mockDeviceKit: MockDeviceKit.shared)
  #endif
  private let wearables: WearablesInterface
  @State private var wearablesViewModel: WearablesViewModel

  init() {
    do {
      try Wearables.configure()
    } catch {
      #if DEBUG
      NSLog("[CameraAccess] Failed to configure Wearables SDK: \(error)")
      #endif
    }

    #if DEBUG
    // Start the test server when launched by XCUITests so tests can control
    // mock device setup via HTTP commands from the test process.
    if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
      MockDeviceKit.shared.enable(config: MockDeviceKitConfig(initiallyRegistered: false))

      let portFilePath = ProcessInfo.processInfo.environment["MWDAT_TEST_SERVER_PORT_FILE"]
      Task {
        do {
          _ = try await MockDeviceKit.shared.startTestServer(portFilePath: portFilePath)
        } catch {
          // pika27: errors are not propagated from this unstructured task
        }
      }
    }
    #endif

    // A test that asks for onboarding gets it from the first step, whatever an earlier run saved.
    if LaunchOptions.isUITesting, LaunchOptions.forcesOnboarding {
      A11yPreferences.shared.resetOnboarding()
    }
    // Render the earcons now, so the first tone doesn't wait on engine setup.
    EarconPlayer.shared.prepare()

    let wearables = Wearables.shared
    self.wearables = wearables
    self._wearablesViewModel = State(wrappedValue: WearablesViewModel(wearables: wearables))
  }

  var body: some Scene {
    WindowGroup {
      // Main app view with access to the shared Wearables SDK instance
      // The Wearables.shared singleton provides the core DAT API
      MainAppView(wearables: Wearables.shared, viewModel: wearablesViewModel)
        // Registration and update failures: the title says what happened, the message is the
        // spoken sentence, and the action (if any) is the one next step.
        .alert(wearablesViewModel.errorTitle, isPresented: $wearablesViewModel.showError) {
          if let action = wearablesViewModel.errorAction {
            Button(action.title) {
              wearablesViewModel.performErrorAction()
            }
            Button("Not now", role: .cancel) {
              wearablesViewModel.dismissError()
            }
          } else {
            Button("OK", role: .cancel) {
              wearablesViewModel.dismissError()
            }
          }
        } message: {
          Text(wearablesViewModel.errorMessage)
        }
        // Handles the callbacks from Meta AI, the scene phase for the registration timeout, and
        // registration requests that Meta AI starts.
        .background {
          RegistrationView(viewModel: wearablesViewModel)
        }
        #if DEBUG
      .sheet(isPresented: $showDebugMenu) {
        MockDeviceKitView(viewModel: mockDeviceKitViewModel)
      }
      .overlay {
        DebugMenuView(showDebugMenu: $showDebugMenu)
      }
        #endif
    }
  }
}
