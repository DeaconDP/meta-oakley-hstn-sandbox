/*
 * PhoneCameraViews - the camera screen's camera card: which camera reads (a labelled switch), the
 * phone's live preview while it is the camera, the torch, and the phone camera's problem with its
 * fix (V0 "Glasses optional")
 *
 * VoiceOver: the preview is one image element ("Phone camera view"); the switch is a picker named
 * "Camera" with the choice as its value; the torch is a switch. Dynamic Type: the segmented
 * switch becomes a menu at accessibility sizes, and every text wraps. Styled from A11y/Theme.
 */

import AVFoundation
import SwiftUI
import UIKit

struct CameraSourceCard: View {
  var router: CameraSourceRouter
  /// "Connect my glasses", for choosing the glasses before they are linked.
  var connectGlasses: () -> Void

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      sourcePicker
      if router.active == .phone {
        if let problem = router.phoneProblem {
          problemView(problem)
        } else if let phone = router.phone as? PhoneFrameSource {
          PhoneCameraPreview(session: phone.session, isRunning: phone.isRunning)
        }
        if router.phone.hasTorch {
          Toggle(isOn: Binding(get: { router.phone.isTorchOn }, set: { router.setTorch($0) })) {
            Text("Torch")
              .font(.rounded(.headline, weight: .heavy))
              .foregroundStyle(Theme.ink)
          }
          .tint(Theme.listen)
          .frame(minHeight: 60)
          .accessibilityHint("Lights the page in a dark room. You can also say torch on.")
          .accessibilityIdentifier("torch_toggle")
        }
      }
      if router.preference == .glasses, !router.registered {
        Button("Connect my glasses", action: connectGlasses)
          .buttonStyle(.a11ySecondary)
          .accessibilityHint("Opens the Meta AI app to approve the connection, then come back.")
      }
    }
    .themeCard()
  }

  private var sourcePicker: some View {
    let binding = Binding(get: { router.preference }, set: { router.choose($0) })
    return VStack(alignment: .leading, spacing: 6) {
      Text("Camera")
        .font(.rounded(.headline, weight: .heavy))
        .foregroundStyle(Theme.ink)
        .accessibilityHidden(true)
      // The App Store build has no glasses: nothing to choose, only the caption.
      if GlassesSupport.isBuiltIn {
        Group {
          if dynamicTypeSize.isAccessibilitySize {
            Picker("Camera", selection: binding) {
              ForEach(CameraSourcePreference.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
          } else {
            Picker("Camera", selection: binding) {
              ForEach(CameraSourcePreference.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
          }
        }
        .accessibilityLabel("Camera")
        .accessibilityHint("Choose the iPhone's camera, your glasses, or automatic. You can also say use the phone or use the glasses.")
        .accessibilityIdentifier("camera_source_picker")
      }
      Text(caption)
        .font(.rounded(.subheadline, weight: .semibold))
        .foregroundStyle(Theme.inkSoft)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// What is reading now, in words (colour and position alone don't say it).
  private var caption: String {
    switch router.active {
    case .phone:
      return router.fellBack ? "Using the iPhone's camera: your glasses aren't connected." : "Using the iPhone's camera. Hold it about 30 cm above the page."
    case .glasses:
      return "Using your glasses' camera."
    }
  }

  private func problemView(_ problem: PhoneCameraProblem) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      ConnectionNoticeView(text: problem.spokenLine)
        .accessibilityLabel("\(problem.title). \(problem.spokenLine)")
        .accessibilityIdentifier("phone_camera_problem")
      if problem.opensSettings, let url = URL(string: UIApplication.openSettingsURLString) {
        Button("Open Settings") { UIApplication.shared.open(url) }
          .buttonStyle(.a11ySecondary)
          .accessibilityHint("Opens SpeakUp's settings, where you can turn on Camera.")
      }
    }
  }
}

/// The phone camera's live picture. Hidden from VoiceOver as a picture it can't describe, but kept
/// as one element so a low-vision user knows it is there.
struct PhoneCameraPreview: View {
  let session: AVCaptureSession
  var isRunning: Bool

  var body: some View {
    PreviewLayerView(session: session, isRunning: isRunning)
      .frame(maxWidth: .infinity)
      .frame(height: 220)
      .background(Color.black)
      .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
      .overlay {
        if !isRunning {
          Text("The camera starts when you read.")
            .font(.rounded(.body, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding()
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Phone camera view")
      .accessibilityValue(isRunning ? "On" : "Off until you read")
      .accessibilityAddTraits(.isImage)
      .accessibilityIdentifier("phone_camera_preview")
  }
}

private struct PreviewLayerView: UIViewRepresentable {
  let session: AVCaptureSession
  /// Passed so the view updates when the camera starts: the layer's connection exists only then.
  var isRunning: Bool

  func makeUIView(context: Context) -> PreviewUIView {
    let view = PreviewUIView()
    view.previewLayer.session = session
    view.previewLayer.videoGravity = .resizeAspectFill
    return view
  }

  func updateUIView(_ uiView: PreviewUIView, context: Context) {
    // Portrait, like the frames the reader gets.
    if let connection = uiView.previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
      connection.videoRotationAngle = 90
    }
  }

  final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer {
      // swiftlint:disable:next force_cast
      layer as! AVCaptureVideoPreviewLayer
    }
  }
}
