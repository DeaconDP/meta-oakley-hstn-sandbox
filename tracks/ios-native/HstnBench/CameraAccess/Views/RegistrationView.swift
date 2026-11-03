/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// RegistrationView.swift
//
// Background view that handles callbacks from the Meta AI mobile app during
// DAT SDK registration and permission flows. This invisible view processes deep links
// that complete the OAuth authorization process initiated by the DAT SDK.
//
// HstnBench: it also reports the scene phase to WearablesViewModel (so the registration timeout
// only counts time spent back in this app), and presents the explanation screen when Meta AI
// starts a registration itself. The outcome is spoken by the view model.
//

import MWDATCore
import SwiftUI

struct RegistrationView: View {
  var viewModel: WearablesViewModel

  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    // Zero-sized rather than EmptyView, so the sheet below has a view to present from.
    Color.clear
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
      // Handle callback URLs from the Meta mobile app
      // This is essential for completing DAT SDK registration and permission flows
      .onOpenURL { url in
        Task { await viewModel.handleCallbackURL(url) }
      }
      .onChange(of: scenePhase, initial: true) { _, phase in
        viewModel.scenePhaseChanged(phase)
      }
      .sheet(item: pendingRequest) { _ in
        MetaAIRegistrationRequestView(
          onContinue: { viewModel.continueRegistrationRequest() },
          onDecline: { viewModel.declineRegistrationRequest() }
        )
        .interactiveDismissDisabled()
      }
  }

  /// Dismissing the sheet any other way counts as "Not now", so Meta AI always gets an answer.
  private var pendingRequest: Binding<PendingRegistrationRequest?> {
    Binding(
      get: { viewModel.pendingRegistrationRequest },
      set: { newValue in
        if newValue == nil, viewModel.pendingRegistrationRequest != nil {
          viewModel.declineRegistrationRequest()
        }
      }
    )
  }
}

/// Shown when Meta AI asks to connect this app (handleUrl(_:onRegistrationRequest:)), so the user
/// knows what Continue does before being sent back to Meta AI.
struct MetaAIRegistrationRequestView: View {
  var onContinue: () -> Void
  var onDecline: () -> Void

  @AccessibilityFocusState private var titleFocused: Bool

  var body: some View {
    LessonPage {
      Text("Connect to Meta AI?")
        .font(.rounded(.largeTitle, weight: .black))
        .foregroundStyle(Theme.ink)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
        .accessibilityFocused($titleFocused)
      MascotSays(mood: .listening, text: SpokenMessage.metaAIRegistrationRequest)
    } footer: {
      Button("Continue", action: onContinue)
        .buttonStyle(.a11yPrimary)
        .accessibilityHint("Opens the Meta AI app to finish connecting.")
        .accessibilityIdentifier("registration_request_continue_button")
      Button("Not now", action: onDecline)
        .buttonStyle(.a11ySecondary)
        .accessibilityHint("Tells Meta AI not to connect this app.")
        .accessibilityIdentifier("registration_request_decline_button")
    }
    .onAppear { titleFocused = true }
  }
}
