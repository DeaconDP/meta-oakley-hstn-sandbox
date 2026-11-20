/*
 * NoGlassesLink - the App Store build's GlassesLink: no DAT, so never linked and no glasses camera
 *
 * The SpeakUp target (SPEAKUP_NO_DAT) uses it in place of WearablesViewModel. It is compiled into
 * both targets so it can be tested, but only the store build uses it. Asking it to connect says
 * that glasses need the Beta build, once, plainly; nothing opens Meta AI.
 */

import Foundation
import Observation
import UIKit

@Observable
@MainActor
final class NoGlassesLink: GlassesLink {
  var supportsGlasses: Bool { false }
  var registration: GlassesRegistration { .unavailable }
  var isConnecting: Bool { false }
  var connectionNotice: String? { nil }
  var requiresFirmwareUpdate: Bool { false }
  @ObservationIgnored var connectedFollowUp: String?

  private let say: @MainActor (String) -> Void

  init(say: (@MainActor (String) -> Void)? = nil) {
    self.say = say ?? { Announcer.shared.announce($0, earcon: .attention) }
  }

  func connectGlasses() { say(SpokenMessage.glassesNeedBetaBuild) }
  func disconnectGlasses() { say(SpokenMessage.glassesNeedBetaBuild) }
  func dismissError() {}
  func openFirmwareUpdate() async {}
  func openDATGlassesAppUpdate() async {}
  func makeCamera() -> any GlassesCamera { NoGlassesCamera() }
}

/// No glasses: never a device, never a session. The reader never reads from it, because
/// CameraSourceRouter keeps the phone when nothing is linked; if asked, it says why.
@Observable
@MainActor
final class NoGlassesCamera: GlassesCamera, ReadFrameSource {
  var frameSource: any ReadFrameSource { self }

  var hasActiveDevice: Bool { false }
  var hasSession: Bool { false }
  var isSessionActive: Bool { false }
  var isPaused: Bool { false }
  var isBusy: Bool { false }
  var batteryLevel: Int? { nil }
  var wear: GlassesWear { .unknown }
  var hinge: GlassesHinge { .unknown }
  var a11yPhase: CameraPhase { .noDevice }

  var showError = false
  var errorTitle: String { "" }
  var errorMessage: String { "" }
  var errorAction: CameraErrorAction?
  var showCameraPermissionRedirectConfirm = false

  func dismissError() { showError = false }
  func startStreaming() async {}
  func confirmCameraPermissionRedirect(then: (@MainActor () -> Void)?) async {
    showCameraPermissionRedirectConfirm = false
  }
  func hostDisplaySessionIfNeeded() {}
  func endSession() {}
  func waitForDeviceReport(timeout: Duration) async {}
  func statusLine(updateRequired: Bool) -> String { SpokenMessage.glassesNeedBetaBuild }
  func speakStatus(updateRequired: Bool, interrupt: Bool) {
    Announcer.shared.announce(SpokenMessage.glassesNeedBetaBuild, earcon: .attention, interrupt: interrupt)
  }

  // MARK: ReadFrameSource

  var cameraKind: CameraKind { .glasses }
  var latestReadFrame: ReadFrame? { nil }
  func prepareStreamForReading() -> ReadStreamReadiness { .unavailable(SpokenMessage.glassesNeedBetaBuild) }
  func captureStillForReading() async -> UIImage? { nil }
  func stopReadingStream() {}
}

extension SpokenMessage {
  /// The App Store build has no DAT SDK, so it can't use glasses. Said for "connect" and the like.
  static let glassesNeedBetaBuild =
    "Meta glasses work in the SpeakUp Beta app. This version reads with your iPhone's camera."

  /// The App Store build's welcome: the phone only.
  static let welcomeIntroPhoneOnly = "Hi, I'm SpeakUp. I read printed pages out loud with your iPhone's camera."
  static let welcomeStartPhoneOnly = "To start, say continue, or tap Start reading."
}
