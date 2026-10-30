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
// decorative, text uses Dynamic Type styles at 4.5:1 or better in light and dark mode, the page
// scrolls instead of truncating at large sizes, the button is 60 pt tall, and the Meta AI handoff
// is explained before it happens. Outcomes of connecting are spoken by WearablesViewModel.
//

import MWDATCore
import SwiftUI

struct HomeScreenView: View {
  var viewModel: WearablesViewModel

  @ScaledMetric(relativeTo: .largeTitle) private var logoWidth: CGFloat = 120

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        Image(.cameraAccessIcon)
          .resizable()
          .aspectRatio(contentMode: .fit)
          // Grows with text size, but not past what leaves room for the text.
          .frame(width: min(logoWidth, 200))
          .frame(maxWidth: .infinity)
          .a11yDecorative()

        // The name VoiceOver reads for the app icon, so the user knows where they are.
        Text("HSTN Reader")
          .font(.largeTitle.bold())
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityAddTraits(.isHeader)

        VStack(alignment: .leading, spacing: 16) {
          HomeTipRow(
            systemImage: "eyeglasses",
            title: "Start a session",
            text: "Connect to your glasses to get started."
          )
          HomeTipRow(
            systemImage: "video",
            title: "Start preview",
            text: "See the live camera feed from your glasses."
          )
          HomeTipRow(
            systemImage: "hand.tap",
            title: "Capture",
            text: "Take photos and record video with audio from your glasses' microphone."
          )
        }

        VStack(alignment: .leading, spacing: 16) {
          A11yNote(text: SpokenMessage.beforeMetaAIHandoff)

          if let notice = viewModel.connectionNotice {
            ConnectionNoticeView(text: notice)
          }

          // Title kept: the UI tests find this button by "Connect my glasses".
          Button(viewModel.isConnecting ? "Connecting…" : "Connect my glasses") {
            viewModel.connectGlasses()
          }
          .buttonStyle(.a11yPrimary)
          .disabled(viewModel.isConnecting)
          .accessibilityHint(viewModel.isConnecting ? "" : "Opens the Meta AI app to confirm.")
          .accessibilityIdentifier("connect_glasses_button")
        }
      }
      .padding(24)
      .frame(maxWidth: 700, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .background(Color(.systemBackground).ignoresSafeArea())
    // "Connecting…" otherwise only changes visually.
    .a11yAnnounce(onChangeOf: viewModel.isConnecting) { connecting in
      connecting ? "Connecting." : nil
    }
  }
}

/// TipRow (Components/) uses fixed sizes and grey text; this one scales and keeps contrast. The
/// SF Symbols match the asset icons' meaning and scale with the text.
private struct HomeTipRow: View {
  let systemImage: String
  let title: String
  let text: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Image(systemName: systemImage)
        .font(.title3)
        .foregroundStyle(.primary)
        .frame(minWidth: 28)
        .a11yDecorative()
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.headline)
          .foregroundStyle(.primary)
          .accessibilityAddTraits(.isHeader)
        Text(text)
          .font(.body)
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
