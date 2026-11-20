/*
 * WatchWording - the sentences Watch for text speaks and shows
 *
 * Android's res/values strings for the watch tool, with the camera named for the phone or the
 * glasses. Orientation help only: places are "on your left", "ahead", "on your right", never
 * anything about whether it's safe to go (ROADMAP.md > "Awareness, not safety"). Pure.
 */

import Foundation

enum WatchWording {
  static let name = "Watch for text"

  static func help(camera: CameraKind) -> String {
    "Watch for text. Say watch for, then a word or number. Say where is it, or stop watching. "
      + "I can miss things, so silence doesn't mean it isn't there."
  }

  static let askTarget = "What should I watch for? Say a word or a number, like 42, or exit."
  static func startFirst(_ target: String) -> String {
    "I'll tell you when I see \(target). I can miss things, so silence doesn't mean it isn't there. "
      + "Keep using your cane or dog as usual."
  }
  static func start(_ target: String) -> String { "Watching for \(target)." }
  static func resumed(_ target: String) -> String { "Watching for \(target) again." }
  static let didntGetTarget = "Sorry, I didn't get what to watch for. Say a word or a number."
  static func seen(_ target: String, _ place: String) -> String { "\(target), \(place)." }
  static func gone(_ target: String) -> String { "\(target), gone." }
  static func nearMiss(seen: String, target: String) -> String { "I see \(seen), not \(target)." }
  static func whereLastSeen(_ target: String, _ place: String, seconds: Int) -> String {
    "I last saw \(target) \(place), \(seconds) seconds ago."
  }
  static func whereNotSeen(_ target: String) -> String { "I haven't seen \(target) yet. I'm still watching." }
  static let notWatching = "I'm not watching for anything. Say watch for, then a word or number."
  static func whatTarget(_ target: String) -> String { "I'm watching for \(target)." }
  static func whatTargetStopped(_ target: String) -> String {
    "I was watching for \(target), but I've stopped. Say carry on watching to start again."
  }
  static func stopped(_ target: String) -> String {
    "Stopped watching for \(target). Say carry on watching, or watch for something else."
  }
  static let ticksOff = "Ticks off. I'll still tell you if something goes wrong."
  static func ticksEvery(_ seconds: Int) -> String { "I'll tick every \(seconds) seconds while I watch." }

  static func covered(camera: CameraKind) -> String {
    camera == .phone
      ? "I can't see anything. Is something covering the camera on the back of your phone?"
      : "I can't see anything. Is something covering the camera? It's at the front left of your glasses."
  }
  static let dark = "It's too dark for me to read signs here."
  static func viewBack(_ target: String) -> String { "I can see again. Still watching for \(target)." }
  static func slow(seconds: Int) -> String {
    "Reading is slow on this phone. I can only look about every \(seconds) seconds."
  }
  static func noFrames(camera: CameraKind) -> String {
    "I'm not getting pictures from \(camera == .phone ? "the phone's" : "your glasses") camera. I'll keep trying."
  }
  static let ocrFailed = "Text recognition isn't working right now. I'll keep trying."

  /// "on your right", "ahead, close", "on your left, far off".
  static func place(_ spot: WatchSpot, camera: CameraKind) -> String {
    let side =
      switch WatchPosition.side(x: spot.x, centre: WatchPosition.centreX(for: camera)) {
      case .left: "on your left"
      case .ahead: "ahead"
      case .right: "on your right"
      }
    switch WatchPosition.nearness(heightFraction: spot.heightFraction) {
    case .close: return "\(side), close"
    case .far: return "\(side), far off"
    case nil: return side
    }
  }

  static func tickSetting(_ seconds: Int) -> String { seconds == 0 ? "off" : "every \(seconds) s" }
}
