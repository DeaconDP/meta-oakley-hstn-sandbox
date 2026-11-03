/*
 * SpokenMessage+Read - every line the "Read it aloud" demo says besides the text itself
 *
 * Guidance comes in three lengths for the verbosity setting. Short is for people who already
 * know what to do; normal says what and how; detailed adds the why.
 */

extension SpokenMessage {
  // MARK: Read: framing guidance

  static func readGuidance(_ verdict: FramingVerdict, verbosity: Verbosity) -> String? {
    switch verdict {
    case .good:
      return nil
    case .cutOff(let edges):
      return readCutOff(edges, verbosity: verbosity)
    case .noText:
      switch verbosity {
      case .short: return "No text found."
      case .normal: return "No text found. Hold the page about an arm's length away, a little to your right."
      case .detailed:
        return "No text found. Hold the page about an arm's length away, a little to your right. The camera is on the left side of your glasses."
      }
    case .tooDark:
      switch verbosity {
      case .short: return "Too dark."
      case .normal, .detailed: return "Too dark to read. Turn on a light or move somewhere brighter, then read again."
      }
    case .tooBlurry:
      switch verbosity {
      case .short: return "Too blurry."
      case .normal, .detailed: return "Too blurry to read. Hold your head and the page still, then read again."
      }
    case .tooSmall:
      switch verbosity {
      case .short: return "Text too small. Move closer."
      case .normal: return "The text is too small from here. Move a little closer, then read again."
      case .detailed: return "The text is too small from here, even in a photo. Move a little closer, about a forearm's length, then read again."
      }
    }
  }

  /// See ReadFraming for why "right" in the image is the wearer's right.
  static func readCutOff(_ edges: Set<FramingEdge>, verbosity: Verbosity) -> String {
    let horizontal = edges.contains(.left) && edges.contains(.right)
    let vertical = edges.contains(.top) && edges.contains(.bottom)
    if horizontal || vertical {
      let sides = horizontal && vertical ? "on every side" : (horizontal ? "on both sides" : "at the top and bottom")
      switch verbosity {
      case .short: return "Cut off \(sides). Move back."
      case .normal: return "Text runs off \(sides). Move back a little. Reading what I can see."
      case .detailed: return "Text runs off \(sides), so the page is too close. Move back a little and read again. Reading what I can see."
      }
    }
    let places = FramingEdge.allCases.filter(edges.contains).map { edge in
      switch edge {
      case .left: "on the left"
      case .right: "on the right"
      case .top: "at the top"
      case .bottom: "at the bottom"
      }
    }
    var turns: [String] = []
    if edges.contains(.left) { turns.append("turn your head slightly left") }
    if edges.contains(.right) { turns.append("turn your head slightly right") }
    if edges.contains(.top) { turns.append(turns.isEmpty ? "tilt your head up" : "tilt it up") }
    if edges.contains(.bottom) { turns.append(turns.isEmpty ? "tilt your head down" : "tilt it down") }
    let place = places.joined(separator: " and ")
    let turn = turns.joined(separator: " and ")
    switch verbosity {
    case .short:
      let shortTurns = FramingEdge.allCases.filter(edges.contains).map { edge in
        switch edge {
        case .left: "left"
        case .right: "right"
        case .top: "up"
        case .bottom: "down"
        }
      }
      return "Cut off \(place). Turn \(shortTurns.joined(separator: " and "))."
    case .normal:
      return "Text is cut off \(place). \(turn.prefix(1).uppercased() + turn.dropFirst()). Reading what I can see."
    case .detailed:
      return "Text is cut off \(place). \(turn.prefix(1).uppercased() + turn.dropFirst()), then read again. Reading what I can see."
    }
  }

  // MARK: Read: progress and failures

  static let readStartingCamera = "Starting the camera to read."

  static let readTakingPhotoNoFrame = "No recent camera picture. Taking a photo to read."

  static let readTakingPhotoSmallText = "Small print. Taking a sharper photo."

  static let readPhotoFailed = "The photo for reading wasn't taken. Try again."

  static let readNoCamera = "The camera isn't ready. Open the camera screen and start the preview."

  static let readCameraTimedOut = "The camera didn't start in time. Try reading again."

  static let readFailed = "Text recognition failed on this picture. Try reading again."

  static let readNothingToNavigate = "Nothing read yet. Use Read text first."

  static let readLastSentence = "That was the last sentence."

  static func readEnd(verbosity: Verbosity) -> String {
    verbosity == .short ? "End." : "End of text."
  }

  // MARK: Read: numbers that aren't read

  static func readWithheld(_ kind: SensitiveKind) -> String {
    switch kind {
    case .dose: "a dose I can't read reliably"
    case .money: "an amount I can't read reliably"
    }
  }

  static func readCheckWithheld(_ kind: SensitiveKind) -> String {
    switch kind {
    case .dose: "Check this dose with a pharmacist or another reader."
    case .money: "Check this amount another way."
    }
  }

  // MARK: Launch

  static let launchReading = "Reading."
}
