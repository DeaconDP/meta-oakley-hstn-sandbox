/*
 * CameraNarration - wires CameraView's state changes to CameraNarrator, plus the quick actions
 * every camera-screen element offers to VoiceOver
 *
 * Kept out of CameraView so the view stays about layout, and so the many onChange handlers don't
 * sit on one long modifier chain.
 */

import SwiftUI

struct CameraNarration: ViewModifier {
  let viewModel: CameraViewModel
  let narrator: CameraNarrator
  let updateRequired: @MainActor () -> Bool

  func body(content: Content) -> some View {
    content
      .onChange(of: viewModel.a11yPhase) { old, new in
        narrator.phaseChanged(from: old, to: new, viewModel: viewModel)
      }
      .onChange(of: viewModel.donState) { old, new in
        narrator.donStateChanged(from: old, to: new, viewModel: viewModel)
      }
      .onChange(of: viewModel.hingeState) { old, new in
        narrator.hingeStateChanged(from: old, to: new, viewModel: viewModel)
      }
      .onChange(of: viewModel.batteryLevel) { old, new in
        narrator.batteryChanged(from: old, to: new)
      }
      .onChange(of: viewModel.isRecording) { _, new in
        narrator.recordingChanged(to: new)
      }
      .onChange(of: viewModel.includeAudioInStream) { _, new in
        narrator.micChanged(to: new, isRecording: viewModel.isRecording)
      }
      .onChange(of: viewModel.activePreview?.id) { old, _ in
        narrator.previewChanged(hadPreview: old != nil, to: viewModel.activePreview)
      }
      .onChange(of: viewModel.showError) { _, shown in
        if shown { narrator.errorShown(viewModel) }
      }
      .onChange(of: viewModel.showCameraPermissionRedirectConfirm) { _, shown in
        if shown { narrator.cameraPermissionPromptShown() }
      }
      .onDisappear { narrator.screenDisappeared() }
  }
}

extension View {
  /// VoiceOver custom actions (swipe up/down on any camera-screen element): hear the status line,
  /// or hear the last spoken line again.
  func cameraQuickActions(status: @escaping () -> Void) -> some View {
    accessibilityAction(named: "Status", status)
      .accessibilityAction(named: "Repeat last") { Announcer.shared.repeatLast() }
  }
}
