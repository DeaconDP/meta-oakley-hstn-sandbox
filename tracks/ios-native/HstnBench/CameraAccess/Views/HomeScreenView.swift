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
      .onAppear { VoiceControl.shared.setScreen(.home, handler: handleVoice) }
      .onDisappear { VoiceControl.shared.clearScreen { $0 == .home } }
  }

  /// Help, stop, repeat, faster and slower are VoiceControl's own.
  private func handleVoice(_ command: VoiceCommand) -> Bool {
    switch command {
    case .connect: viewModel.connectGlasses()
    case .status: Announcer.shared.announce(SpokenMessage.voiceHomeStatus, earcon: .attention)
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
        Text("HSTN Reader")
          .font(.rounded(.largeTitle, weight: .black))
          .foregroundStyle(Theme.ink)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityAddTraits(.isHeader)

        VStack(alignment: .leading, spacing: 0) {
          HomeTipRow(
            systemImage: "eyeglasses",
            tone: .green,
            title: "Start a session",
            text: "Connect to your glasses to get started."
          )
          HomeTipDots()
          HomeTipRow(
            systemImage: "video.fill",
            tone: .blue,
            title: "Start preview",
            text: "See the live camera feed from your glasses."
          )
          HomeTipDots()
          HomeTipRow(
            systemImage: "hand.tap.fill",
            tone: .purple,
            title: "Capture",
            text: "Take photos and record video with audio from your glasses' microphone."
          )
        }

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

/// One step of what's ahead, drawn like a lesson on the path. Not a button: it explains.
private struct HomeTipRow: View {
  let systemImage: String
  let tone: Tone
  let title: String
  let text: String

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @ScaledMetric(relativeTo: .title3) private var coinSize: CGFloat = 52

  var body: some View {
    let stacked = dynamicTypeSize.isAccessibilitySize
    let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
    layout {
      TileCoin(icon: systemImage, tone: tone, size: min(coinSize, 96))
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.rounded(.title3, weight: .heavy))
          .foregroundStyle(Theme.ink)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityAddTraits(.isHeader)
        Text(text)
          .font(.rounded(.body, weight: .medium))
          .foregroundStyle(Theme.inkSoft)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// The dots joining the tips, under the coins.
private struct HomeTipDots: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    if dynamicTypeSize.isAccessibilitySize {
      Color.clear.frame(height: 16).accessibilityHidden(true)
    } else {
      VStack(spacing: 3) {
        ForEach(0..<2, id: \.self) { _ in
          Circle().fill(Theme.stroke).frame(width: 7, height: 7)
        }
      }
      .frame(width: 52)
      .padding(.vertical, 3)
      .accessibilityHidden(true)
    }
  }
}
