/*
 * CameraProblem - what the camera screen says when something fails, and the one thing to do next
 *
 * notes/a11y-onboarding.md, "Recovery messages": every failure gets a spoken sentence, an earcon
 * and one action, never just "something went wrong". The SDK's own descriptions are developer
 * wording, so the cases a user can act on are mapped to SpokenMessage lines here; anything else
 * falls back to the SDK text with a "try again".
 */

import MWDATCamera
import MWDATCore

/// The single next step offered with an error. The camera screen turns it into an alert button and
/// performs it.
enum CameraErrorAction: Equatable, Sendable {
  case startSession
  case startPreview
  /// Re-runs the preview start, which checks permission and explains the Meta AI switch first.
  case allowCamera
  case updateGlassesApp
  case openSettings

  var title: String {
    switch self {
    case .startSession: "Start session"
    case .startPreview: "Start preview"
    case .allowCamera: "Allow camera"
    case .updateGlassesApp: "Update in Meta AI"
    case .openSettings: "Open Settings"
    }
  }
}

struct CameraProblem: Equatable, Sendable {
  /// Short alert title; the message carries the full sentence.
  var title: String
  var message: String
  var action: CameraErrorAction?

  static func session(_ error: DeviceSessionError) -> CameraProblem {
    switch error {
    case .noEligibleDevice:
      CameraProblem(title: "Glasses not connected", message: SpokenMessage.glassesNotConnected, action: .startSession)
    case .thermalCritical, .thermalEmergency:
      CameraProblem(title: "Glasses too hot", message: SpokenMessage.glassesTooHot, action: nil)
    case .batteryCritical:
      CameraProblem(title: "Battery too low", message: SpokenMessage.glassesBatteryTooLow, action: nil)
    case .peakPowerShutdown:
      CameraProblem(title: "Power limit", message: SpokenMessage.glassesPowerLimit, action: .startSession)
    case .datAppOnTheGlassesUpdateRequired:
      CameraProblem(title: "Update required", message: SpokenMessage.glassesAppUpdateRequired, action: .updateGlassesApp)
    default:
      CameraProblem(title: "Session problem", message: fallback(error.localizedDescription), action: .startSession)
    }
  }

  static func stream(_ error: StreamError) -> CameraProblem {
    switch error {
    case .permissionDenied:
      CameraProblem(title: "Camera access needed", message: SpokenMessage.cameraPermissionDenied, action: .allowCamera)
    case .hingesClosed:
      CameraProblem(title: "Glasses folded", message: SpokenMessage.glassesFolded, action: nil)
    case .deviceNotFound, .deviceNotConnected:
      CameraProblem(title: "Glasses not connected", message: SpokenMessage.glassesNotConnected, action: nil)
    case .thermalHot:
      CameraProblem(title: "Glasses too hot", message: SpokenMessage.glassesTooHot, action: nil)
    case .batteryLow:
      CameraProblem(title: "Battery too low", message: SpokenMessage.glassesBatteryTooLow, action: nil)
    case .peakPowerLimit:
      CameraProblem(title: "Power limit", message: SpokenMessage.glassesPowerLimit, action: .startPreview)
    case .timeout:
      CameraProblem(title: "No response", message: SpokenMessage.cameraTimedOut, action: .startPreview)
    case .photoCaptureFailed:
      CameraProblem(title: "Photo not taken", message: SpokenMessage.photoFailed, action: nil)
    case .videoStreamingError, .audioStreamingError, .internalError:
      CameraProblem(title: "Camera stopped", message: SpokenMessage.cameraStreamFailed, action: .startPreview)
    @unknown default:
      CameraProblem(title: "Camera problem", message: fallback(error.localizedDescription), action: .startPreview)
    }
  }

  /// Errors from checking or requesting camera permission (typed as PermissionError by the SDK).
  static func permission(_ error: any Error) -> CameraProblem {
    if let error = error as? PermissionError, error == .metaAINotInstalled {
      return CameraProblem(title: "Meta AI needed", message: SpokenMessage.metaAINotInstalled, action: nil)
    }
    return CameraProblem(title: "Camera access problem", message: fallback(error.localizedDescription), action: .allowCamera)
  }

  /// A plain message from the view model (no SDK error), offered with "try again" where useful.
  static func plain(_ message: String, title: String = "Couldn't do that", action: CameraErrorAction? = nil) -> CameraProblem {
    CameraProblem(title: title, message: message, action: action)
  }

  /// SDK text, made into a sentence with a next step.
  private static func fallback(_ description: String) -> String {
    let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return SpokenMessage.cameraStreamFailed }
    let sentence = trimmed.hasSuffix(".") ? trimmed : trimmed + "."
    return sentence + " Try again."
  }
}
