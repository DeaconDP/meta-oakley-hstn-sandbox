/*
 * DATGlassesInputs - glasses buttons and touchpad into SpeakUp ("Your buttons", C4, Experimental)
 *
 * The only file that touches DAT's Inputs capability (MWDATInputs, dev and beta only). On a STARTED
 * DeviceSession, while glasses buttons are on (ControlsArea), it adds Inputs and turns each
 * InputEvent into a GlassesControl for GlassesControls, which runs the mapped action. Switching
 * glasses buttons off removes the capability, so the glasses' own button actions come back.
 *
 * DAT 1.0 (linked 1.0.1), from the MWDATInputs interface and docs/develop/dat/inputs:
 * - `DeviceSession.addInputs(configuration:) throws -> Inputs?`, `removeInputs()`.
 * - `Inputs.events: AsyncStream<InputEvent>`; events are nav(direction:), select, back,
 *   button(.action), capture(.shortPress / .hold / .doublePress), drag.
 * - Single tap and tap-and-hold on the touchpad are reserved (pause, stop) and never arrive.
 * - `consumeBack` is false here: SpeakUp has no use for Back, so the glasses keep it.
 * - Known issues: a double press arrives as a short press then a double press (GlassesControls
 *   waits for it), and inputs stop after the glasses are taken off and put on again; re-adding the
 *   capability fixes it, which reattach() does when the wearer puts them back on.
 *
 * In the CameraAccess (Beta) target only; the SpeakUp target leaves this file out.
 */

import Foundation
import MWDATCore
import MWDATInputs

@MainActor
final class DATGlassesInputs {
  static let shared = DATGlassesInputs()

  private weak var session: DeviceSession?
  private var inputs: Inputs?
  private var listening: Task<Void, Never>?

  private init() {
    ControlsArea.shared.onEnabledChanged = { [weak self] on in
      guard let self else { return }
      if on, let session = self.session { self.attach(to: session) } else if !on { self.removeInputs() }
    }
  }

  /// A session reached STARTED. Adds Inputs if glasses buttons are on. A failure only loses the
  /// buttons, never the session.
  func attach(to session: DeviceSession) {
    self.session = session
    guard ControlsArea.shared.enabled, inputs == nil else { return }
    let configuration = InputsConfiguration(sources: [.captureButton, .captouch, .actionButton], consumeBack: false)
    do {
      guard let inputs = try session.addInputs(configuration: configuration) else {
        NSLog("[SpeakUp] glasses inputs unavailable on this device")
        return
      }
      self.inputs = inputs
      listen(to: inputs)
    } catch {
      NSLog("[SpeakUp] glasses inputs unavailable: \(error)")
    }
  }

  /// The glasses went back on: DAT's known issue means inputs need adding again.
  func reattach() {
    guard let session else { return }
    removeInputs()
    attach(to: session)
  }

  /// The session ended.
  func detach() {
    listening?.cancel()
    listening = nil
    inputs = nil
    session = nil
  }

  private func removeInputs() {
    listening?.cancel()
    listening = nil
    guard inputs != nil else { return }
    inputs = nil
    try? session?.removeInputs()
  }

  private func listen(to inputs: Inputs) {
    listening?.cancel()
    let events = inputs.events
    listening = Task { @MainActor in
      for await event in events {
        guard let control = Self.control(for: event) else { continue }
        GlassesControls.shared.receive(control)
      }
    }
  }

  /// The app's name for a DAT event, or nil for one SpeakUp doesn't map (back, drag).
  static func control(for event: InputEvent) -> GlassesControl? {
    switch event {
    case .capture(let press, _, _):
      switch press {
      case .shortPress: .captureShort
      case .hold: .captureHold
      case .doublePress: .captureDouble
      }
    case .select: .doubleTap
    case .nav(let direction, _, _):
      switch direction {
      case .up: .swipeUp
      case .down: .swipeDown
      case .left: .swipeLeft
      case .right: .swipeRight
      }
    case .button(let button, _, _):
      switch button {
      case .action: .actionButton
      }
    case .back, .drag: nil
    @unknown default: nil
    }
  }
}
