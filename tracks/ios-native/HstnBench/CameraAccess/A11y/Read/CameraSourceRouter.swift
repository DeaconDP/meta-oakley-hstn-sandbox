/*
 * CameraSourceRouter - the ReadFrameSource TextReader reads from: the phone camera or the glasses,
 * switchable while the app runs (V0 "Glasses optional", notes/phone-camera-ios.md)
 *
 * The camera screen tells it about the glasses (their source, whether SpeakUp is linked to them,
 * whether they are around) and it forwards each reader call to the camera CameraSourcePolicy picks.
 * Switching stops the camera being left, says which camera is now in use, and plays an earcon.
 *
 * Auto with linked glasses that don't turn up within the screen's usual wait (CameraNarrator's
 * appear sequence) falls back to the phone and says so once. If they turn up later, it goes back
 * to them and says so: at once if nothing is being read, otherwise at the next read.
 *
 * A switch by voice or on screen is saved as the setting (A11yPreferences.cameraSource), so it
 * holds on the next launch too.
 *
 * No DAT imports: the glasses come in as a plain ReadFrameSource.
 */

import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class CameraSourceRouter: ReadFrameSource {
  static let shared = CameraSourceRouter()

  /// What the user picked (A11yPreferences.cameraSource), except that UI tests keep the old
  /// glasses-only screens unless launched with --phone-camera. The App Store build (no DAT) is
  /// always the phone.
  var preference: CameraSourcePreference {
    if !GlassesSupport.isBuiltIn { return .phone }
    if LaunchOptions.isUITesting, !LaunchOptions.usesPhoneCamera, preferenceOverride == nil { return .glasses }
    return preferenceOverride ?? preferences.cameraSource
  }

  /// SpeakUp is linked to glasses (WearablesViewModel.registrationState == .registered).
  var registered = false {
    didSet { if registered != oldValue { activeMayHaveChanged() } }
  }

  /// The linked glasses are around (CameraViewModel.hasActiveDevice).
  var glassesConnected = false {
    didSet {
      guard glassesConnected != oldValue else { return }
      if glassesConnected, fellBack, !isReaderBusy() {
        // Auto had fallen back to the phone; the glasses are here now.
        fellBack = false
        glassesWaitOver = false
        say(SpokenMessage.glassesBackFromFallback, .connected)
      }
      activeMayHaveChanged()
    }
  }

  /// The camera screen's wait for the glasses is over (or a read needed an answer sooner).
  private(set) var glassesWaitOver = false
  /// Auto is on the phone because the linked glasses didn't turn up.
  private(set) var fellBack = false

  var active: CameraKind {
    // Fallen back: stays on the phone until the glasses arrive while nothing is being read.
    if preference == .auto, fellBack { return .phone }
    return CameraSourcePolicy.resolve(
      preference, registered: registered, glassesConnected: glassesConnected, glassesWaitOver: glassesWaitOver)
  }

  /// Set by the camera screen while it is up (CameraViewModel).
  @ObservationIgnored weak var glasses: (any ReadFrameSource)?
  @ObservationIgnored let phone: any PhoneCamera

  @ObservationIgnored private let preferences: A11yPreferences
  /// A choice made in this run that the stored setting doesn't express: in UI tests (see
  /// `preference`) and in unit tests.
  private var preferenceOverride: CameraSourcePreference?
  @ObservationIgnored private let say: @MainActor (String, Earcon?) -> Void
  @ObservationIgnored private let isReaderBusy: @MainActor () -> Bool
  @ObservationIgnored private var lastActive: CameraKind?

  init(
    preferences: A11yPreferences = .shared,
    phone: (any PhoneCamera)? = nil,
    say: (@MainActor (String, Earcon?) -> Void)? = nil,
    isReaderBusy: (@MainActor () -> Bool)? = nil,
    preferenceOverride: CameraSourcePreference? = nil
  ) {
    self.preferences = preferences
    self.phone = phone ?? PhoneFrameSource()
    self.say = say ?? { text, earcon in Announcer.shared.announce(text, earcon: earcon, interrupt: false) }
    self.isReaderBusy = isReaderBusy ?? { TextReader.shared.isActive }
    self.preferenceOverride = preferenceOverride
  }

  // MARK: The camera screen

  /// The appear sequence has waited for the glasses. Auto with linked glasses that didn't come:
  /// the phone, said once.
  func glassesWaitEnded() {
    guard !glassesWaitOver else { return }
    glassesWaitOver = true
    if CameraSourcePolicy.isFallback(preference, registered: registered, glassesConnected: glassesConnected, glassesWaitOver: true) {
      fellBack = true
      say(SpokenMessage.glassesFallbackToPhone, .attention)
    }
    activeMayHaveChanged()
  }

  /// The screen went away: the next appearance waits for the glasses again.
  func screenDisappeared() {
    glassesWaitOver = false
    fellBack = false
    phone.stopReadingStream()
  }

  // MARK: Switching

  /// The setting changed on screen, or by voice. Returns the line said (also for tests).
  @discardableResult
  func choose(_ newPreference: CameraSourcePreference) -> String {
    let before = active
    let samePreference = newPreference == preference
    setPreference(newPreference)
    fellBack = false
    let line: String
    switch newPreference {
    case .auto:
      line = SpokenMessage.cameraAutomatic
    case .phone:
      line = samePreference && before == .phone ? SpokenMessage.cameraAlreadyInUse(.phone) : SpokenMessage.cameraSwitched(to: .phone)
    case .glasses:
      if !registered {
        line = SpokenMessage.glassesNeedConnecting
      } else if samePreference && before == .glasses {
        line = SpokenMessage.cameraAlreadyInUse(.glasses)
      } else {
        line = glassesConnected ? SpokenMessage.cameraSwitched(to: .glasses) : SpokenMessage.glassesNotAroundYet
      }
    }
    say(line, .listening)
    activeMayHaveChanged()
    return line
  }

  /// "which camera"
  var whichCameraLine: String {
    SpokenMessage.whichCamera(active, preference: preference, canUseGlasses: registered)
  }

  /// "torch on" / "torch off". Says the result and returns it.
  @discardableResult
  func setTorch(_ on: Bool) -> TorchResult {
    let result = active == .phone ? phone.setTorch(on) : .glassesInUse
    let earcon: Earcon = switch result {
    case .on, .off: .done
    case .noTorch, .glassesInUse: .attention
    case .failed: .error
    }
    say(SpokenMessage.torch(result), earcon)
    return result
  }

  /// The phone camera's current problem, for the screen and its narration.
  var phoneProblem: PhoneCameraProblem? { phone.problem }

  /// The status line for the phone camera, or nil when the glasses are in use (their own line).
  var phoneStatusLine: String? {
    guard active == .phone else { return nil }
    if let problem = phone.problem { return problem.spokenLine }
    return phone.isRunning ? SpokenMessage.phoneCameraOn : SpokenMessage.phoneReady
  }

  private func setPreference(_ newPreference: CameraSourcePreference) {
    if preferenceOverride != nil || (LaunchOptions.isUITesting && !LaunchOptions.usesPhoneCamera) {
      preferenceOverride = newPreference
    }
    preferences.cameraSource = newPreference
  }

  /// Stops the camera that is no longer in use, so the phone's camera light and the glasses'
  /// stream don't run for nothing.
  private func activeMayHaveChanged() {
    let now = active
    defer { lastActive = now }
    guard let lastActive, lastActive != now else { return }
    switch lastActive {
    case .phone: phone.stopReadingStream()
    case .glasses: glasses?.stopReadingStream()
    }
  }

  private var current: (any ReadFrameSource)? {
    active == .phone ? phone : glasses
  }

  // MARK: ReadFrameSource

  var cameraKind: CameraKind { active }

  var latestReadFrame: ReadFrame? { current?.latestReadFrame }

  func prepareStreamForReading() -> ReadStreamReadiness {
    // Auto with linked glasses that aren't here: don't make the reader wait for them.
    if !glassesWaitOver, preference == .auto, registered, !glassesConnected, glasses != nil {
      glassesWaitEnded()
    }
    // The glasses arrived during the last read: this new one uses them.
    if fellBack, glassesConnected {
      fellBack = false
      say(SpokenMessage.glassesBackFromFallback, .connected)
      activeMayHaveChanged()
    }
    guard let current else { return .unavailable(SpokenMessage.readNoCamera) }
    return current.prepareStreamForReading()
  }

  func captureStillForReading() async -> UIImage? {
    await current?.captureStillForReading()
  }

  func stopReadingStream() {
    current?.stopReadingStream()
  }
}

// MARK: - Light (DarkWatch)

extension CameraSourceRouter: ReadLightSource {
  var sceneEV: Double? { active == .phone ? phone.sceneEV : nil }

  var canOfferTorch: Bool { active == .phone && phone.hasTorch && !phone.isTorchOn }

  func turnTorchOn() { setTorch(true) }
}
