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

// CameraPhase and cameraBatteryWarningPercent are in A11y/Glasses/GlassesLink.swift, so the App
// Store build (no DAT) has them too.

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
    case .idle, .sessionReady: text = SpokenMessage.readyToRead
    case .sessionStarting, .previewStarting: text = SpokenMessage.cameraStarting
    case .waitingForDevice: text = SpokenMessage.waitingForGlasses
    case .stopping: text = SpokenMessage.stopping
    case .paused:
      text = donState == .doffed ? SpokenMessage.glassesRemoved : SpokenMessage.paused
      earcon = .attention
    case .streaming: text = SpokenMessage.cameraOn
    }
    if let batteryLevel, batteryLevel <= cameraBatteryWarningPercent {
      text += " " + SpokenMessage.batteryLow(percent: batteryLevel)
    }
    return (text, earcon)
  }
}
