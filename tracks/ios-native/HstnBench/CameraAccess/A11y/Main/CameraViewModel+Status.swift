/*
 * CameraViewModel+Status - the camera screen's spoken status line and its coarse phase
 *
 * notes/a11y-onboarding.md, "Launch (every day)": one short line, either "Ready" or the single
 * blocker and how to fix it, spoken on appear and on demand. Built only from state the view model
 * already gets from DAT: the active device, its DeviceState (battery, worn, folded), the session
 * and stream states, and the last camera-permission query.
 */

import Foundation
import MWDATCamera
import MWDATCore

/// The camera screen's state as a user thinks of it. Announcements fire on changes of this, so a
/// session and its stream moving together (both pausing, say) are heard once.
enum CameraPhase: Equatable, Sendable {
  case noDevice
  /// Glasses active, no session.
  case idle
  case sessionStarting
  /// Session started, no stream.
  case sessionReady
  case previewStarting
  case waitingForDevice
  case streaming
  case paused
  case stopping

  /// A wait the user should hear ticking.
  var isWaiting: Bool {
    switch self {
    case .sessionStarting, .previewStarting, .waitingForDevice, .stopping: true
    default: false
    }
  }
}

/// Battery at or below this is mentioned in the status line and announced once when crossed.
let cameraBatteryWarningPercent = 20

extension CameraViewModel {
  var a11yPhase: CameraPhase {
    if sessionState == .stopping || streamState == .stopping { return .stopping }
    if !hasSession { return hasActiveDevice ? .idle : .noDevice }
    if sessionState == .starting { return .sessionStarting }
    if sessionState == .paused || streamState == .paused { return .paused }
    switch streamState {
    case .starting: return .previewStarting
    case .waitingForDevice: return .waitingForDevice
    case .streaming: return .streaming
    case .paused: return .paused
    case .stopping: return .stopping
    case .stopped: return .sessionReady
    }
  }

  /// The status line: the first blocker with its fix, otherwise what the screen is ready for.
  /// `updateRequired` comes from WearablesViewModel.requiresFirmwareUpdate (not visible here).
  func statusLine(updateRequired: Bool = false) -> String {
    statusLineAndEarcon(updateRequired: updateRequired).text
  }

  /// Speaks `statusLine(updateRequired:)` with an earcon: "ready" when nothing blocks, otherwise
  /// "attention". Callable from anywhere on the main actor (screen appear, Status action, launch).
  func speakStatus(updateRequired: Bool = false, interrupt: Bool = true) {
    let line = statusLineAndEarcon(updateRequired: updateRequired)
    Announcer.shared.announce(line.text, earcon: line.earcon, interrupt: interrupt)
  }

  private func statusLineAndEarcon(updateRequired: Bool) -> (text: String, earcon: Earcon) {
    if !hasActiveDevice { return (SpokenMessage.glassesNotConnected, .attention) }
    if updateRequired { return (SpokenMessage.firmwareUpdateNeeded, .attention) }
    if hingeState == .closed { return (SpokenMessage.glassesFoldedIdle, .attention) }
    if donState == .doffed, !hasSession { return (SpokenMessage.glassesNotWorn, .attention) }
    if cameraPermission == .denied, !isStreaming { return (SpokenMessage.cameraPermissionOff, .attention) }

    var text: String
    var earcon = Earcon.ready
    switch a11yPhase {
    case .noDevice: return (SpokenMessage.glassesNotConnected, .attention)
    case .idle: text = SpokenMessage.readyToStartSession
    case .sessionStarting: text = SpokenMessage.sessionStarting
    case .sessionReady: text = SpokenMessage.readyToStartPreview
    case .previewStarting: text = SpokenMessage.cameraStarting
    case .waitingForDevice: text = SpokenMessage.waitingForGlasses
    case .stopping: text = SpokenMessage.stopping
    case .paused:
      text = donState == .doffed ? SpokenMessage.glassesRemoved : SpokenMessage.paused
      earcon = .attention
    case .streaming: text = SpokenMessage.cameraOn
    }
    if isRecording { text = SpokenMessage.recording(elapsed: spokenRecordingElapsed) + " " + text }
    if let batteryLevel, batteryLevel <= cameraBatteryWarningPercent {
      text += " " + SpokenMessage.batteryLow(percent: batteryLevel)
    }
    return (text, earcon)
  }

  /// "1 minute, 5 seconds", for VoiceOver values and the status line.
  var spokenRecordingElapsed: String {
    guard let recordingStartDate else { return "starting" }
    return Self.spokenDuration(Date().timeIntervalSince(recordingStartDate))
  }

  static func spokenDuration(_ seconds: TimeInterval) -> String {
    let whole = max(0, Int(seconds))
    return Duration.seconds(whole).formatted(.units(allowed: [.minutes, .seconds], width: .wide))
  }
}
