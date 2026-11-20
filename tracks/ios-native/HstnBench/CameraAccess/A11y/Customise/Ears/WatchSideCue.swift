/*
 * WatchSideCue - Watch for text's "it's on your left" as sound as well as words
 *
 * Before the sighting's attention earcon plays, this marks it with the side the text is on
 * (AudioShape.sideCue): panned towards that side in stereo; with mono on, or alerts sent to one
 * ear, a lower tone for left and a higher one for right. "on your left" is spoken either way, so
 * the cue only adds to the words and nothing is lost with earcons off.
 */

import Foundation

enum WatchSideCue {
  static func cue(for spot: WatchSpot, camera: CameraKind, shape: AudioShape) -> SideCue {
    shape.sideCue(for: WatchPosition.side(x: spot.x, centre: WatchPosition.centreX(for: camera)))
  }

  static func mark(_ spot: WatchSpot, camera: CameraKind) {
    let cue = cue(for: spot, camera: camera, shape: AudioShapeStore.current)
    guard cue != .plain else { return }
    AudioBus.shared.placeNext(.attention, cue: cue)
  }
}
