/*
 * DATGlassesLink - the glasses build's GlassesLink and GlassesCamera: WearablesViewModel and
 * CameraViewModel, with DAT's types turned into the app's own (GlassesLink.swift)
 *
 * In the CameraAccess (Beta) target only. The SpeakUp (App Store) target leaves this file out
 * (a membership exception in the project) and uses NoGlassesLink instead.
 */

import MWDATCore

extension WearablesViewModel: GlassesLink {
  var supportsGlasses: Bool { true }

  var registration: GlassesRegistration {
    switch registrationState {
    case .registered: .registered
    case .registering: .registering
    case .available: .available
    case .unavailable: .unavailable
    @unknown default: .unavailable
    }
  }

  func makeCamera() -> any GlassesCamera {
    CameraViewModel(wearables: wearables)
  }
}

extension CameraViewModel: GlassesCamera {
  var frameSource: any ReadFrameSource { self }

  var wear: GlassesWear {
    if donState == .doffed { return .doffed }
    if donState == .donned { return .donned }
    return .unknown
  }

  var hinge: GlassesHinge {
    if hingeState == .closed { return .closed }
    if hingeState == .unknown { return .unknown }
    return .open
  }
}
