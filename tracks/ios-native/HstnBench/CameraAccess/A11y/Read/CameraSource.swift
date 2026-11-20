/*
 * CameraSource - which camera the reader uses: the iPhone's own or the glasses' (V0 "Glasses
 * optional", notes/phone-camera-ios.md)
 *
 * The setting (A11yPreferences.cameraSource) is auto, phone or glasses. Auto means the phone until
 * the glasses are linked to SpeakUp; once linked, the glasses, falling back to the phone (said once)
 * when they don't turn up within the screen's usual wait. Pure, so the rules are unit tested.
 * Nothing here imports the DAT SDK, so it can go into a build without it.
 */

import Foundation

/// The user's choice. Stored by raw value.
enum CameraSourcePreference: String, CaseIterable, Identifiable, Sendable {
  case auto
  case phone
  case glasses

  var id: String { rawValue }

  var title: String {
    switch self {
    case .auto: "Automatic"
    case .phone: "Phone"
    case .glasses: "Glasses"
    }
  }
}

/// The camera actually in use.
enum CameraKind: String, Equatable, Sendable {
  case phone
  case glasses

  /// "the phone camera" / "the glasses camera", for spoken lines.
  var spokenName: String {
    switch self {
    case .phone: "the phone camera"
    case .glasses: "the glasses camera"
    }
  }
}

enum CameraSourcePolicy {
  /// The camera to read with.
  /// - registered: SpeakUp is linked to glasses through Meta AI.
  /// - glassesConnected: the linked glasses are around right now.
  /// - glassesWaitOver: the camera screen has waited its usual time for them to report.
  static func resolve(
    _ preference: CameraSourcePreference, registered: Bool, glassesConnected: Bool, glassesWaitOver: Bool
  ) -> CameraKind {
    switch preference {
    case .phone: return .phone
    case .glasses: return .glasses
    case .auto:
      guard registered else { return .phone }
      if glassesConnected { return .glasses }
      return glassesWaitOver ? .phone : .glasses
    }
  }

  /// Auto has given up on linked glasses that didn't turn up, so "Glasses not connected. Using the
  /// phone camera." is due.
  static func isFallback(
    _ preference: CameraSourcePreference, registered: Bool, glassesConnected: Bool, glassesWaitOver: Bool
  ) -> Bool {
    preference == .auto && registered && !glassesConnected && glassesWaitOver
  }

  /// Whether the main (camera) screen shows. Without linked glasses it still does, with the phone
  /// camera, unless the user asked for the glasses: then the connect screen shows.
  static func showsCameraScreen(_ preference: CameraSourcePreference, registered: Bool) -> Bool {
    registered || preference != .glasses
  }
}

/// Why the phone camera can't read right now.
enum PhoneCameraProblem: Equatable, Sendable {
  /// The user said no to camera access, or turned it off in Settings.
  case permissionDenied
  /// Camera access is blocked by Screen Time or a device profile.
  case permissionRestricted
  /// No back camera (the Simulator, some iPads).
  case noCamera
  /// The camera couldn't be set up (inputs or outputs refused).
  case setupFailed
  /// Another app, a call or split view took the camera.
  case interrupted
  /// The capture session stopped with an error.
  case stoppedWithError

  /// What to say. Leads with what happened, then one next step.
  var spokenLine: String {
    switch self {
    case .permissionDenied: SpokenMessage.phoneCameraPermissionDenied
    case .permissionRestricted: SpokenMessage.phoneCameraRestricted
    case .noCamera: SpokenMessage.phoneCameraUnavailable
    case .setupFailed: SpokenMessage.phoneCameraSetupFailed
    case .interrupted: SpokenMessage.phoneCameraInterrupted
    case .stoppedWithError: SpokenMessage.phoneCameraStopped
    }
  }

  /// Short title for the screen.
  var title: String {
    switch self {
    case .permissionDenied, .permissionRestricted: "Camera access is off"
    case .noCamera: "No camera available"
    case .setupFailed, .stoppedWithError: "Camera didn't start"
    case .interrupted: "Camera in use elsewhere"
    }
  }

  /// The Settings app can fix it.
  var opensSettings: Bool { self == .permissionDenied }
}

/// The torch command's outcome.
enum TorchResult: Equatable, Sendable {
  case on
  case off
  /// This camera has no torch.
  case noTorch
  /// The glasses are the camera; the torch belongs to the phone.
  case glassesInUse
  case failed
}

extension SpokenMessage {
  // MARK: Phone camera (V0)

  static let phoneCameraPermissionDenied =
    "Camera access is off for SpeakUp. To turn it on, open the Settings app, choose Apps, then SpeakUp, and turn on Camera."

  static let phoneCameraRestricted =
    "Camera access is blocked on this iPhone, perhaps by Screen Time. Ask whoever manages the phone to allow the camera."

  static let phoneCameraUnavailable = "No camera available on this device."

  static let phoneCameraSetupFailed = "The phone camera didn't start. Try reading again."

  static let phoneCameraInterrupted =
    "Another app is using the camera. Close it, or come back to SpeakUp full screen, then read again."

  static let phoneCameraStopped = "The phone camera stopped. Try reading again."

  static let phoneCameraResumed = "Phone camera back."

  /// Before iOS asks for camera access the first time.
  static let phoneCameraPermissionAsk = "iPhone will ask to use the camera. Choose Allow."

  static let glassesFallbackToPhone = "Glasses not connected. Using the phone camera."

  static let glassesBackFromFallback = "Glasses connected. Using the glasses camera."

  static func cameraSwitched(to kind: CameraKind) -> String {
    switch kind {
    case .phone: "Using the phone camera. Hold the phone about 30 centimetres above the page."
    case .glasses: "Using the glasses camera."
    }
  }

  static func cameraAlreadyInUse(_ kind: CameraKind) -> String {
    "Already using \(kind.spokenName)."
  }

  static let cameraAutomatic = "Camera set to automatic: your glasses when they're connected, otherwise the phone."

  /// "use the glasses" without linked glasses: the connect screen follows.
  static let glassesNeedConnecting = "To use your glasses, connect them first. Say connect, or tap Connect my glasses."

  static let glassesNotAroundYet = "Using the glasses camera. Your glasses aren't connected yet, so check Bluetooth."

  static func whichCamera(_ kind: CameraKind, preference: CameraSourcePreference, canUseGlasses: Bool) -> String {
    let now = "You're using \(kind.spokenName)"
    let auto = preference == .auto ? ", chosen automatically" : ""
    let other: String
    switch kind {
    case .phone: other = canUseGlasses ? " Say use the glasses to switch." : ""
    case .glasses: other = " Say use the phone to switch."
    }
    return "\(now)\(auto).\(other)"
  }

  static let torchOn = "Torch on."
  static let torchOff = "Torch off."
  static let torchUnavailable = "This iPhone's camera has no torch. Move somewhere brighter."
  static let torchGlasses = "The torch is on the phone. Say use the phone first."
  static let torchFailed = "The torch didn't switch. Try again."

  static func torch(_ result: TorchResult) -> String {
    switch result {
    case .on: torchOn
    case .off: torchOff
    case .noTorch: torchUnavailable
    case .glassesInUse: torchGlasses
    case .failed: torchFailed
    }
  }

  static let phoneReady = "Ready to read with the phone camera."
  static let phoneCameraOn = "Phone camera on. Ready to read."
}
