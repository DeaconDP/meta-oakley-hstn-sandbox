/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// CapturePreviewView.swift
//
// Shared preview/share screen for captures from Meta wearable devices via the
// DAT SDK. Photos (Stream.capturePhoto()) and recorded videos use the same
// chrome — a media view plus Share and Close — so the two flows are consistent
// and captures aren't written straight to the library. Share hands the capture
// to the system share sheet, which includes "Save Image/Video" to Photos.
//

import AVKit
import SwiftUI

struct CapturePreviewView: View {
  let preview: CapturePreview
  let onDismiss: () -> Void

  @State private var player: AVPlayer?
  @State private var showShareSheet = false

  init(preview: CapturePreview, onDismiss: @escaping () -> Void) {
    self.preview = preview
    self.onDismiss = onDismiss
    if case .video(let url) = preview {
      _player = State(initialValue: AVPlayer(url: url))
    }
  }

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    ZStack {
      Theme.page
        .ignoresSafeArea()
        .onTapGesture { dismiss() }
        .accessibilityHidden(true)

      VStack(spacing: 0) {
        HStack {
          Text(isVideo ? "Your video" : "Your photo")
            .font(.rounded(.title2, weight: .black))
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(true)
          Spacer(minLength: 12)
          CircleButton(icon: "xmark", text: nil, accessibilityLabel: "Close") {
            dismiss()
          }
          .accessibilityHint("Returns to the camera.")
          .accessibilityIdentifier("close_preview_button")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)

        ScrollView {
          VStack(spacing: 20) {
            mediaView
              .frame(maxWidth: .infinity)
              // Leaves room for Share when the text is large; 460 pt as before otherwise.
              .frame(maxHeight: dynamicTypeSize.isAccessibilitySize ? 320 : 460)
              .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
              .overlay {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                  .strokeBorder(Theme.stroke, lineWidth: 2)
                  .accessibilityHidden(true)
              }
              .accessibilityIgnoresInvertColors()

            CircleButton(icon: "square.and.arrow.up", text: "Share") {
              showShareSheet = true
            }
            .accessibilityHint(isVideo ? "Save or send the video." : "Save or send the photo.")
            .accessibilityIdentifier("share_button")
          }
          .padding(.horizontal, 20)
          .padding(.bottom, 20)
        }
        .scrollBounceBehavior(.basedOnSize)
      }
    }
    // Over the camera screen: VoiceOver stays inside until it's closed.
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isModal)
    // Two-finger scrub (Escape) closes, like Close; Magic Tap too, so the camera's own Magic Tap
    // (take a photo) is one more two-finger double-tap away.
    .accessibilityAction(.escape) { dismiss() }
    .accessibilityAction(.magicTap) { dismiss() }
    .onAppear { player?.play() }
    .sheet(isPresented: $showShareSheet) {
      ShareSheet(activityItems: [shareItem])
    }
  }

  private var isVideo: Bool {
    if case .video = preview { return true }
    return false
  }

  @ViewBuilder
  private var mediaView: some View {
    switch preview {
    case .photo(let image):
      Image(uiImage: image)
        .resizable()
        .aspectRatio(contentMode: .fit)
        // Short label: the spoken reply (TtsReply) already says what happened.
        .accessibilityLabel("Photo")
        .accessibilityAddTraits(.isImage)
    case .video:
      if let player {
        VideoPlayer(player: player)
          .accessibilityLabel("Recorded video")
      }
    }
  }

  private var shareItem: Any {
    switch preview {
    case .photo(let image): return image
    case .video(let url): return url
    }
  }

  private func dismiss() {
    player?.pause()
    onDismiss()
  }
}

struct ShareSheet: UIViewControllerRepresentable {
  let activityItems: [Any]

  func makeUIViewController(context: Context) -> UIActivityViewController {
    let activityViewController = UIActivityViewController(
      activityItems: activityItems,
      applicationActivities: nil
    )

    activityViewController.excludedActivityTypes = [
      .assignToContact,
      .addToReadingList,
    ]

    return activityViewController
  }

  func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
