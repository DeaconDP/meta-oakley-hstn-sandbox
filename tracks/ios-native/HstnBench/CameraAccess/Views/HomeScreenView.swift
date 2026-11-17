/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// HomeScreenView.swift
//
// Welcome screen that guides users through the DAT SDK registration process.
// This view is displayed when the app is not yet registered.
//
// HstnBench: first run uses OnboardingView instead. This is where the user lands after choosing
// Not now there, or after the glasses are disconnected later.
//
// HstnBench: made usable with VoiceOver and low vision (notes/a11y-onboarding.md): icons are
// decorative, text uses Dynamic Type styles, the page scrolls instead of truncating at large sizes,
// the button is 60 pt tall, and the Meta AI handoff is explained before it happens. Outcomes of
// connecting are spoken by WearablesViewModel. Styled from A11y/Theme.
//

import MWDATCore
import SwiftUI

struct HomeScreenView: View {
  var viewModel: WearablesViewModel

  var body: some View {
    content
      .onAppear {
        VoiceControl.shared.setScreen(.home, handler: handleVoice)
        // Spoken tips after a quiet spell: "say connect". Not while Meta AI is being opened.
        VoiceCoach.shared.provide(for: .home) { [viewModel] in viewModel.isConnecting ? nil : .notLinked }
      }
      .onDisappear {
        VoiceControl.shared.clearScreen { $0 == .home }
        VoiceCoach.shared.stopProviding(for: .home)
      }
  }

  /// Help, stop, repeat, faster, slower, goodbye and the settings but disconnect are VoiceControl's own.
  private func handleVoice(_ command: VoiceCommand) -> Bool {
    switch command {
    case .connect, .tryAgain:
      // An alert left up would sit over Meta AI's return.
      viewModel.dismissError()
      viewModel.connectGlasses()
    case .status: Announcer.shared.announce(SpokenMessage.voiceHomeStatus, earcon: .attention)
    case .disconnect: viewModel.disconnectByVoice()
    default: return false
    }
    return true
  }

  private var content: some View {
    VStack(spacing: 0) {
      PinnedVoiceIndicator()
      LessonPage {
        FlowingVoiceIndicator()

        // The name VoiceOver reads for the app icon, so the user knows where they are.
        VStack(alignment: .leading, spacing: 2) {
          Text("SpeakUp")
            .font(.rounded(.largeTitle, weight: .black))
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
          Text("Your glasses, out loud.")
            .font(.rounded(.title3, weight: .bold))
            .foregroundStyle(Theme.inkSoft)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Text("Connect your glasses once. Then hold up a page, a letter or a label, and SpeakUp reads it to you.")
          .font(.rounded(.body, weight: .medium))
          .foregroundStyle(Theme.ink)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)

        MascotSays(mood: viewModel.connectionNotice == nil ? .happy : .confused, text: SpokenMessage.beforeMetaAIHandoff)

        if let notice = viewModel.connectionNotice {
          ConnectionNoticeView(text: notice)
        }
      } footer: {
        // Title kept: the UI tests find this button by "Connect my glasses".
        Button(viewModel.isConnecting ? "Connecting…" : "Connect my glasses") {
          viewModel.connectGlasses()
        }
        .buttonStyle(.a11yPrimary)
        .sayHint(.connect)
        .disabled(viewModel.isConnecting)
        .accessibilityHint(viewModel.isConnecting ? "" : "Opens the Meta AI app to confirm.")
        .accessibilityIdentifier("connect_glasses_button")
      }
    }
    .background(Theme.page.ignoresSafeArea())
    // "Connecting…" otherwise only changes visually.
    .a11yAnnounce(onChangeOf: viewModel.isConnecting) { connecting in
      connecting ? "Connecting." : nil
    }
  }
}
