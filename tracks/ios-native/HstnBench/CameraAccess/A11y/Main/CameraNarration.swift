/*
 * CameraNarration - wires the main screen's state changes to CameraNarrator, plus the quick actions
 * every main-screen element offers to VoiceOver
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
      .onChange(of: viewModel.showError) { _, shown in
        if shown { narrator.errorShown(viewModel) }
      }
      .onChange(of: viewModel.showCameraPermissionRedirectConfirm) { _, shown in
        if shown { narrator.cameraPermissionPromptShown() }
      }
      .onDisappear { narrator.screenDisappeared() }
  }
}

/// The camera screen's two alerts, answered by voice. While one is up it is a blocking VoiceControl
/// prompt, so commands go to it and not to the screen behind:
/// - "Allow camera access": yes / allow / continue goes ahead (Meta AI opens, then the read carries
///   on); no / not now / cancel cancels; "read" says the question again.
/// - An error: its action's words ("try again", "yes", "update") take the action; OK / no close it;
///   "read" closes it and reads.
/// Every answer closes the alert as well, as its buttons do.
struct CameraVoicePrompts: ViewModifier {
  let viewModel: CameraViewModel
  let narrator: CameraNarrator
  let perform: @MainActor (CameraErrorAction) -> Void

  func body(content: Content) -> some View {
    content
      .onChange(of: viewModel.showError, initial: true) { _, shown in
        if shown { showErrorPrompt() } else { VoiceControl.shared.dismissPrompt(.cameraError) }
      }
      // A second error can replace the first while the alert stays up.
      .onChange(of: viewModel.errorAction) { _, _ in
        if viewModel.showError { showErrorPrompt() }
      }
      .onChange(of: viewModel.showCameraPermissionRedirectConfirm, initial: true) { _, shown in
        if shown { showPermissionPrompt() } else { VoiceControl.shared.dismissPrompt(.cameraPermission) }
      }
      .onDisappear {
        VoiceControl.shared.dismissPrompt(.cameraError)
        VoiceControl.shared.dismissPrompt(.cameraPermission)
      }
  }

  private func showErrorPrompt() {
    let viewModel = viewModel
    let perform = perform
    VoiceControl.shared.showPrompt(.cameraError, accepts: CameraProblem.voiceCommands(for: viewModel.errorAction)) { command in
      let action = viewModel.errorAction
      switch command {
      case .ok, .no:
        Self.close(viewModel)
      case .read:
        Self.close(viewModel)
        TextReader.shared.read()
      case .yes, .tryAgain, .update:
        Self.close(viewModel)
        if let action {
          perform(action)
        } else if command == .tryAgain {
          TextReader.shared.read()
        }
      default:
        return false
      }
      return true
    }
  }

  private func showPermissionPrompt() {
    let viewModel = viewModel
    let narrator = narrator
    VoiceControl.shared.showPrompt(.cameraPermission, accepts: [.yes, .continueOn, .no, .read]) { command in
      switch command {
      case .yes, .continueOn:
        VoiceControl.shared.dismissPrompt(.cameraPermission)
        // The same as the alert's Continue: the read that asked carries on once it's allowed.
        Task { await viewModel.confirmCameraPermissionRedirect { TextReader.shared.read() } }
      case .no:
        VoiceControl.shared.dismissPrompt(.cameraPermission)
        viewModel.showCameraPermissionRedirectConfirm = false
        narrator.cameraPermissionPromptCancelled()
      case .read:
        // Still waiting for an answer: the reader says the question again.
        TextReader.shared.read()
      default:
        return false
      }
      return true
    }
  }

  private static func close(_ viewModel: CameraViewModel) {
    VoiceControl.shared.dismissPrompt(.cameraError)
    viewModel.dismissError()
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
