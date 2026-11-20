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
// Two builds share this entry point (notes/phone-camera-ios.md > "App Store build without the DAT
// SDK"). CameraAccess (Beta) configures DAT and passes WearablesViewModel as the GlassesLink. The
// SpeakUp target (SPEAKUP_NO_DAT) links no DAT, passes NoGlassesLink and reads with the iPhone only.
//

import Foundation
import SwiftUI

#if !SPEAKUP_NO_DAT
import MWDATCore
#if DEBUG
import MWDATMockDevice
#endif
#endif

@main
struct CameraAccessApp: App {
  #if !SPEAKUP_NO_DAT
  #if DEBUG
  // Debug menu for simulating device connections during development. The
  // ladybug button toggles `showDebugMenu`; the sheet hosts the mock device kit.
  @State private var showDebugMenu = false
  @State private var mockDeviceKitViewModel = MockDeviceKitViewModel(mockDeviceKit: MockDeviceKit.shared)
  #endif
  @State private var wearablesViewModel: WearablesViewModel
  #else
  @State private var noGlasses = NoGlassesLink()
  #endif

  init() {
    #if !SPEAKUP_NO_DAT
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
    #endif

    // A test that asks for onboarding gets the first-run screen, whatever an earlier run saved.
    if LaunchOptions.isUITesting, LaunchOptions.forcesOnboarding {
      A11yPreferences.shared.resetOnboarding()
    }
    // Render the earcons now, so the first tone doesn't wait on engine setup.
    EarconPlayer.shared.prepare()
    // And look up the voice, so the first word doesn't wait on that.
    AppVoice.shared.prepare()
    // Make it your own: settings areas, undo and keep, profiles, and settings by voice.
    MakeItYourOwn.start()

    #if !SPEAKUP_NO_DAT
    self._wearablesViewModel = State(wrappedValue: WearablesViewModel(wearables: Wearables.shared))
    #endif
  }

  var body: some Scene {
    WindowGroup {
      #if SPEAKUP_NO_DAT
      // The App Store build: the phone camera only. speakup://handsfree still opens hands-free.
      MainAppView(link: noGlasses)
        .readsImports()
        .onOpenURL { url in
          if HandsFreeMode.isHandsFreeURL(url) { VoiceControl.shared.startHandsFreeFromLaunch() }
        }
      #else
      // Main app view with the glasses link (WearablesViewModel wraps the shared Wearables SDK).
      MainAppView(link: wearablesViewModel)
        .readsImports()
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
      #endif
    }
  }
}
