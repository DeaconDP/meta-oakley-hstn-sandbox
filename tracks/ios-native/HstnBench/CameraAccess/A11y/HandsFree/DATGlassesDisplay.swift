/*
 * DATGlassesDisplay - the hands-free card on a Meta Ray-Ban Display, through MWDATDisplay (GA in
 * DAT 1.0.1)
 *
 * The only file that touches the Display API. It is attached to a STARTED DeviceSession whose
 * device reports supportsDisplay (CameraViewModel), and GlassesDisplaySink decides what and when
 * to send. Each send is one FlexBox that replaces the screen: title, state, last heard, and the
 * hints as buttons that run the same command as saying them.
 *
 * No SwiftUI here on purpose: MWDATDisplay's Text, Button and Image would clash with SwiftUI's.
 */

import Foundation
import MWDATCore
import MWDATDisplay

@MainActor
final class DATGlassesDisplay: GlassesDisplayTarget {
  private let display: Display

  private init(display: Display) {
    self.display = display
  }

  /// Adds and starts the Display capability. Throws if the session can't host one.
  static func attach(to session: DeviceSession) throws -> DATGlassesDisplay {
    let display = try session.addDisplay()
    display.start()
    return DATGlassesDisplay(display: display)
  }

  /// Display.start() returns at once; content can be sent once its state is `.started`.
  private func waitUntilStarted(timeout: Duration = .seconds(10)) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while display.state != .started {
      if display.state == .stopped || clock.now >= deadline || Task.isCancelled { return false }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return true
  }

  func send(_ card: HandsFreeCard, onCommand: @escaping @MainActor @Sendable (VoiceCommand) -> Void) async throws {
    guard await waitUntilStarted() else { throw DisplayError.displayError("The display didn't start.") }
    try await display.send(Self.view(for: card, onCommand: onCommand))
  }

  func clear() async {
    try? await display.clearDisplay()
  }

  func detach() {
    display.stop()
  }

  /// The card as Display DSL. Pure apart from the button callbacks.
  nonisolated static func view(
    for card: HandsFreeCard, onCommand: @escaping @MainActor @Sendable (VoiceCommand) -> Void
  ) -> FlexBox {
    FlexBox(direction: .column, spacing: 8) {
      Text(card.title, style: .heading)
      Text(card.state, style: .body)
      if let heard = card.heard {
        Text(heard, style: .meta, color: .secondary)
      }
      if !card.hints.isEmpty {
        Text("Say:", style: .meta, color: .secondary)
        ButtonGroup {
          for command in card.hints {
            Button(label: command.phrase, style: .secondary, onClick: { Task { @MainActor in onCommand(command) } })
          }
        }
      }
    }
    .padding(16)
    .background(.card)
  }
}
