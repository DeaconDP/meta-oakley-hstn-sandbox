/*
 * CameraNarration - wires the main screen's state changes to CameraNarrator, plus the quick actions
 * every main-screen element offers to VoiceOver
 *
 * Kept out of CameraView so the view stays about layout, and so the many onChange handlers don't
 * sit on one long modifier chain.
 */

import SwiftUI

struct CameraNarration: ViewModifier {
  let viewModel: any GlassesCamera
  let narrator: CameraNarrator
  let updateRequired: @MainActor () -> Bool
  /// The camera permission prompt's Continue and Cancel, so the question can be answered by voice.
  let permissionYes: @MainActor () -> Void
  let permissionNo: @MainActor () -> Void

  func body(content: Content) -> some View {
    content
      .onChange(of: viewModel.a11yPhase) { old, new in
        narrator.phaseChanged(from: old, to: new, viewModel: viewModel)
      }
      .onChange(of: viewModel.wear) { old, new in
        narrator.wearChanged(from: old, to: new, viewModel: viewModel)
      }
      .onChange(of: viewModel.hinge) { old, new in
        narrator.hingeChanged(from: old, to: new, viewModel: viewModel)
      }
      .onChange(of: viewModel.batteryLevel) { old, new in
        narrator.batteryChanged(from: old, to: new)
      }
      .onChange(of: viewModel.showError) { _, shown in
        guard shown else { return }
        narrator.errorShown(viewModel)
        // Hands-free has no alert to dismiss; the action stays for "try again".
        if A11yPreferences.shared.handsFree { viewModel.dismissError() }
      }
      .onChange(of: viewModel.showCameraPermissionRedirectConfirm) { _, shown in
        if shown {
          narrator.cameraPermissionPromptShown(yes: permissionYes, no: permissionNo)
        } else {
          VoiceControl.shared.clearQuestion()
        }
      }
      .onDisappear { narrator.screenDisappeared() }
  }
}

extension View {
  /// VoiceOver custom actions (swipe up/down on any camera-screen element): read the text in
  /// view, hear the status line, or hear the last spoken line again. While there is something
  /// read, also next / previous / repeat sentence, and stop while reading.
  func cameraQuickActions(status: @escaping () -> Void) -> some View {
    modifier(CameraQuickActions(status: status))
  }
}

private struct CameraQuickActions: ViewModifier {
  let status: () -> Void

  func body(content: Content) -> some View {
    let reader = TextReader.shared
    content
      .accessibilityAction(named: "Read text") { reader.read() }
      .accessibilityAction(named: "Status", status)
      .accessibilityAction(named: "Repeat last") { Announcer.shared.repeatLast() }
      .accessibilityActions {
        if reader.hasSentences {
          Button("Next sentence") { reader.next() }
          Button("Previous sentence") { reader.previous() }
          Button("Repeat sentence") { reader.repeatSentence() }
        }
        if reader.isActive {
          Button("Stop reading") { reader.stop() }
        }
      }
  }
}
