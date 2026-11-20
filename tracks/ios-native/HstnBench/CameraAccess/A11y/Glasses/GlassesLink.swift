/*
 * GlassesLink and GlassesCamera - what the screens need from Meta glasses, with no DAT types
 * (notes/phone-camera-ios.md > "App Store build without the DAT SDK")
 *
 * The screens (MainAppView, OnboardingView, HomeScreenView, CameraView) and the narration
 * (CameraNarrator, CameraNarration) only see these protocols. Two builds fill them in:
 *
 * - CameraAccess (Beta, glasses): WearablesViewModel and CameraViewModel, through
 *   DATGlassesLink.swift. Only that build links the DAT SDK.
 * - SpeakUp (App Store, SPEAKUP_NO_DAT): NoGlassesLink and NoGlassesCamera. Meta's docs say an app
 *   that links DAT is rejected from the App Store, so this build reads with the iPhone only.
 */

import Foundation

/// Whether this build can use Meta glasses at all.
enum GlassesSupport {
  #if SPEAKUP_NO_DAT
  static let isBuiltIn = false
  #else
  static let isBuiltIn = true
  #endif
}

/// SpeakUp's link to glasses through Meta AI, as an app enum (DAT's RegistrationState).
enum GlassesRegistration: Equatable, Sendable {
  case unavailable
  case available
  case registering
  case registered
}

/// Whether the glasses are on the face (DAT's DonState).
enum GlassesWear: Equatable, Sendable {
  case unknown
  case donned
  case doffed
}

/// Whether the glasses are folded (DAT's HingeState).
enum GlassesHinge: Equatable, Sendable {
  case unknown
  case open
  case closed
}

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

/// The single next step offered with a camera error. The camera screen turns it into an alert
/// button and performs it.
enum CameraErrorAction: Equatable, Sendable {
  /// Reads again, which starts the camera again on the way.
  case tryAgain
  /// Re-runs the camera start, which checks permission and explains the Meta AI switch first.
  case allowCamera
  case updateGlassesApp
  case openSettings

  var title: String {
    switch self {
    case .tryAgain: "Try again"
    case .allowCamera: "Allow camera"
    case .updateGlassesApp: "Update in Meta AI"
    case .openSettings: "Open Settings"
    }
  }
}

/// Registration with Meta AI, updates, and the camera for the main screen.
@MainActor
protocol GlassesLink: AnyObject {
  /// False in the App Store build: no connect buttons, and "connect" says glasses need the Beta.
  var supportsGlasses: Bool { get }
  var registration: GlassesRegistration { get }
  /// From the user choosing Connect until success, cancel, failure or timeout.
  var isConnecting: Bool { get }
  /// Why the last attempt didn't connect, shown next to the connect button.
  var connectionNotice: String? { get }
  var requiresFirmwareUpdate: Bool { get }
  /// Appended to the next "Connected to …" line.
  var connectedFollowUp: String? { get set }

  func connectGlasses()
  func disconnectGlasses()
  func dismissError()
  func openFirmwareUpdate() async
  func openDATGlassesAppUpdate() async
  /// A new camera for the main screen. Each CameraView owns the one it makes.
  func makeCamera() -> any GlassesCamera
}

extension GlassesLink {
  var isRegistered: Bool { registration == .registered }
}

/// The glasses' camera and state for the main screen: status, phase, worn, folded, battery, and
/// the errors and permission prompt it raises.
@MainActor
protocol GlassesCamera: AnyObject {
  /// The same object as the reader's frame source (CameraSourceRouter.glasses).
  var frameSource: any ReadFrameSource { get }

  var hasActiveDevice: Bool { get }
  var hasSession: Bool { get }
  var isSessionActive: Bool { get }
  var isPaused: Bool { get }
  var isBusy: Bool { get }
  var batteryLevel: Int? { get }
  var wear: GlassesWear { get }
  var hinge: GlassesHinge { get }
  var a11yPhase: CameraPhase { get }

  var showError: Bool { get set }
  var errorTitle: String { get }
  var errorMessage: String { get }
  var errorAction: CameraErrorAction? { get set }
  var showCameraPermissionRedirectConfirm: Bool { get set }

  func dismissError()
  func startStreaming() async
  func confirmCameraPermissionRedirect(then: (@MainActor () -> Void)?) async
  /// Hands-free on glasses with a display: a session so the card can show.
  func hostDisplaySessionIfNeeded()
  /// Waits until the device stream has reported (or `timeout`).
  func waitForDeviceReport(timeout: Duration) async
  /// The spoken status line: the first blocker with its fix, otherwise what is ready.
  func statusLine(updateRequired: Bool) -> String
  func speakStatus(updateRequired: Bool, interrupt: Bool)
}

extension GlassesCamera {
  /// What a tip should be about on the main screen, or nil when nothing should be suggested.
  func coachSituation(updateRequired: Bool, hasReadSentences: Bool) -> CoachSituation? {
    // An alert owns the moment; the update has its own button and line.
    if showError || showCameraPermissionRedirectConfirm || updateRequired {
      return nil
    }
    if !hasActiveDevice { return .noGlasses }
    if hinge == .closed || (wear == .doffed && !hasSession) { return .glassesNotReady }
    switch a11yPhase {
    case .idle, .sessionReady, .streaming: return hasReadSentences ? .afterReading : .ready
    case .paused: return .paused
    case .noDevice: return .noGlasses
    case .sessionStarting, .previewStarting, .waitingForDevice, .stopping: return nil
    }
  }
}
