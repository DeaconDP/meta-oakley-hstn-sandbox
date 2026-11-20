/*
 * ImportPicker - "read a photo", "read a file" and "import" by voice open ImportButton's pickers
 *
 * The voice handler (CameraView.handleVoice) can't present ImportButton's dialog or pickers, which
 * are that view's state. It says what comes next, then parks a request here; ImportButton observes
 * `pending` and takes it, also when it appears later (a tool was open, so the button wasn't on
 * screen yet). One slot, latest wins. A request expires after `maxAge`, so a button that only
 * appears much later doesn't open a picker nobody asked for just now.
 *
 * The pickers stay the system's (touch, VoiceOver, Voice Control); only getting to them is by voice.
 */

import Foundation
import Observation

@MainActor
@Observable
final class ImportPicker {
  static let shared = ImportPicker()

  enum Request: Equatable, Sendable {
    /// "Choose a photo" / "Choose a file".
    case choice
    case photo
    case file
  }

  /// The request waiting for ImportButton. Observe it; take it with consume().
  private(set) var pending: Request?

  let maxAge: TimeInterval

  @ObservationIgnored private var requestedAt: Date?
  @ObservationIgnored private let now: () -> Date

  init(maxAge: TimeInterval = 15, now: @escaping () -> Date = Date.init) {
    self.maxAge = maxAge
    self.now = now
  }

  func request(_ request: Request) {
    requestedAt = now()
    pending = request
  }

  /// Takes the waiting request, or nil if there is none or it expired. Always clears the slot.
  func consume() -> Request? {
    defer {
      pending = nil
      requestedAt = nil
    }
    guard let pending, let requestedAt, now().timeIntervalSince(requestedAt) <= maxAge else { return nil }
    return pending
  }

  /// The request a voice command makes, if it opens a picker.
  static func request(for command: VoiceCommand) -> Request? {
    switch command {
    case .readPhoto: .photo
    case .readFile: .file
    case .readPhotoOrFile, .readShared: .choice
    default: nil
    }
  }
}
