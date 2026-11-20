/*
 * DarkWatch - "It's dark" before reading, not after OCR (notes/phone-reading-ios.md)
 *
 * The phone camera knows how much light there is from its own exposure: ISO, shutter time and
 * aperture give the scene's exposure value (EV at ISO 100), whatever is printed on the page. A page
 * of white text on black has a dark frame but a normal EV, so EV is used whenever the camera gives
 * it. Without it (the glasses, a fake in tests) the frame's mean brightness stands in, with a
 * stricter threshold.
 *
 * Hysteresis: it turns dark below the enter threshold and light again only above the exit one, so
 * a reading on the edge doesn't flip between the two. It warns once per dark spell. Reading again
 * while it is still dark reads anyway: the user heard the warning and wants to try.
 *
 * Thresholds are [est], to check on real phones. EV 3 is roughly 20 lux (a dim living room at
 * night), EV 4 roughly 40 lux. Vision still finds large print around 20 lux but small print fails,
 * and the frames get noisy.
 */

import Foundation

/// The scene's exposure value from the camera's settings. Pure.
enum SceneLight {
  /// EV at ISO 100: log2(N² / t) − log2(ISO / 100). nil for values a camera can't report.
  static func ev100(aperture: Double, exposureSeconds: Double, iso: Double) -> Double? {
    guard aperture > 0, exposureSeconds > 0, iso > 0, aperture.isFinite, exposureSeconds.isFinite, iso.isFinite else { return nil }
    return log2(aperture * aperture / exposureSeconds) - log2(iso / 100)
  }
}

/// A camera that can say how light the scene is and offer its torch. PhoneFrameSource and
/// CameraSourceRouter (when the phone is in use) conform.
@MainActor
protocol ReadLightSource: AnyObject {
  /// EV at ISO 100 from the camera's exposure, or nil when unknown.
  var sceneEV: Double? { get }
  /// There is a torch, it is off, and this camera is the one in use.
  var canOfferTorch: Bool { get }
  /// Turns the torch on and says so.
  func turnTorchOn()
}

struct DarkWatch: Equatable {
  /// Dark below this EV, light again above `evExit`. [est]
  static let evEnter = 3.0
  static let evExit = 4.0
  /// Without EV: dark below this mean frame brightness (0...1), light again above `brightnessExit`.
  /// Stricter than the framing check's 0.16, because a dark frame can be light text on black. [est]
  static let brightnessEnter = 0.10
  static let brightnessExit = 0.16

  enum Decision: Equatable {
    /// Read as usual.
    case read
    /// Say it's dark and don't run OCR this time.
    case warn
  }

  private(set) var isDark = false
  /// The warning was given in this dark spell.
  private(set) var warned = false

  /// One read's measurement. `ev` wins when known.
  mutating func check(ev: Double?, brightness: Double?) -> Decision {
    if let ev {
      isDark = isDark ? ev < Self.evExit : ev < Self.evEnter
    } else if let brightness {
      isDark = isDark ? brightness < Self.brightnessExit : brightness < Self.brightnessEnter
    }
    guard isDark else {
      warned = false
      return .read
    }
    if warned { return .read }
    warned = true
    return .warn
  }
}
