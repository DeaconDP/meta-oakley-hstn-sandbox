/*
 * ImportedReading - reads pages that arrive from outside the camera (share sheet, Photos, Files)
 *
 * Contract between the main screen and the import feature: whoever receives an image or PDF
 * parks it here and requests LaunchAction.readImported; the main screen calls readPending()
 * when it can. Placeholder until the import feature lands.
 */

import Foundation

@MainActor
enum ImportedReading {
  /// True when something is waiting to be read.
  static var hasPending: Bool { false }
  /// Reads whatever is waiting, then clears it. Does nothing when nothing is waiting.
  static func readPending() {}
}
