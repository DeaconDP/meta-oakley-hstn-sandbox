/*
 * SpokenMessage+Read - every line the "Read it aloud" demo says besides the text itself
 *
 * Guidance comes in three lengths for the verbosity setting. Short is for people who already
 * know what to do; normal says what and how; detailed adds the why.
 */

extension SpokenMessage {
  // MARK: Read: framing guidance

  /// `camera`: the phone gets its own wording ("move the phone", "say torch on"); the glasses'
  /// wording below is unchanged.
  static func readGuidance(_ verdict: FramingVerdict, verbosity: Verbosity, camera: CameraKind = .glasses) -> String? {
    if camera == .phone { return readGuidancePhone(verdict, verbosity: verbosity) }
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

  /// The phone's back camera, held over the page in portrait: image right is the user's right as
  /// they look at the screen, so text cut off on the right means moving the phone right.
  static func readGuidancePhone(_ verdict: FramingVerdict, verbosity: Verbosity) -> String? {
    switch verdict {
    case .good:
      return nil
    case .cutOff(let edges):
      let horizontal = edges.contains(.left) && edges.contains(.right)
      let vertical = edges.contains(.top) && edges.contains(.bottom)
      if horizontal || vertical {
        switch verbosity {
        case .short: return "Cut off. Raise the phone."
        case .normal, .detailed: return "Text runs off the edges. Raise the phone a little. Reading what I can see."
        }
      }
      let moves = FramingEdge.allCases.filter(edges.contains).map { edge in
        switch edge {
        case .left: "left"
        case .right: "right"
        case .top: "up the page"
        case .bottom: "down the page"
        }
      }
      let move = moves.joined(separator: " and ")
      switch verbosity {
      case .short: return "Cut off. Move the phone \(move)."
      case .normal, .detailed: return "Text is cut off. Move the phone a little \(move). Reading what I can see."
      }
    case .noText:
      switch verbosity {
      case .short: return "No text found."
      case .normal: return "No text found. Hold the phone flat, about 30 centimetres above the page."
      case .detailed:
        return "No text found. Hold the phone flat, screen up, about 30 centimetres above the page, with the page in the middle."
      }
    case .tooDark:
      switch verbosity {
      case .short: return "Too dark. Say torch on."
      case .normal, .detailed: return "Too dark to read. Say torch on, or move somewhere brighter, then read again."
      }
    case .tooBlurry:
      switch verbosity {
      case .short: return "Too blurry."
      case .normal, .detailed: return "Too blurry to read. Hold the phone and the page still, then read again."
      }
    case .tooSmall:
      switch verbosity {
      case .short: return "Text too small. Move closer."
      case .normal, .detailed: return "The text is too small from here. Bring the phone a little closer to the page, then read again."
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

  static let readNoCamera = "The camera isn't ready yet. Try again in a moment."

  static let readCameraTimedOut = "The camera didn't start in time. Try reading again."

  static let readFailed = "Text recognition failed on this picture. Try reading again."

  static let readNothingToNavigate = "Nothing read yet. Use Read text first."

  static let readLastSentence = "That was the last sentence."

  static func readEnd(verbosity: Verbosity) -> String {
    verbosity == .short ? "End." : "End of text."
  }

  // MARK: Read: natural voice (cloud)

  /// Any cloud error; the phone's OCR or voice carries on straight after.
  static let readCloudFallback = "Couldn't reach the reading service, reading on the phone instead."

  static let readCloudKeySaved = "Key saved. Reading uses the natural voice."

  static let readCloudKeySavedVoiceOff = "Key saved. Turn on Use natural voice to read with it."

  static let readCloudKeyNotSaved = "That key wasn't saved. Paste the whole key and try again."

  static let readCloudKeyRemoved = "Key removed. Reading uses the phone's voice."

  /// Removed the pasted key, but the build has one of its own.
  static let readCloudKeyRemovedBuiltIn = "Key removed. Reading uses the key built into this app."

  static let readNaturalVoiceOn = "Natural voice on."

  static let readNaturalVoiceOff = "Natural voice off. Reading stays on the phone."

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

  // MARK: Read: dark warning (DarkWatch)

  static let readDarkWarning = "It's dark. Say torch on, or move somewhere brighter."

  /// Asked once per run, after the warning, when the phone has a torch that is off.
  static let readTorchOffer = "Shall I turn the torch on? Say yes, or tap Torch on."

  static let readTorchDeclined = "OK. Say torch on any time."

  // MARK: Read: haptics setting

  static let readHapticsOn = "Framing haptics on."

  static let readHapticsOff = "Framing haptics off."

  // MARK: Read: big text

  static let bigTextOn = "Big text."

  static let bigTextOff = "Big text off."

  static let bigTextNothing = "Nothing read yet. Read something first, then say big text."

  // MARK: Read: steps

  static let stepsNothingRead = "Nothing read yet. Read a recipe or a manual first, then say next step."

  static let stepsNone = "I didn't find numbered steps on this page. Say next to hear the next sentence."

  static func stepsCount(_ count: Int) -> String {
    count == 1 ? "1 step." : "\(count) steps."
  }

  static func stepsLeft(_ count: Int) -> String {
    switch count {
    case 0: "No steps left. That was the last one."
    case 1: "1 step left."
    default: "\(count) steps left."
    }
  }

  static func stepPosition(_ index: Int, of count: Int) -> String {
    "You're on step \(index + 1) of \(count)."
  }

  static func stepsNotStarted(_ count: Int) -> String {
    "You haven't started the steps. There \(count == 1 ? "is 1" : "are \(count)"). Say next step for step 1."
  }

  static let stepLast = "That was the last step. Say repeat step to hear it again."

  static let stepFirst = "This is the first step."

  /// Said before a step printed without a number (a bullet or a paragraph).
  static func stepLabel(_ index: Int) -> String {
    "Step \(index + 1)."
  }

  // MARK: Launch

  static let launchReading = "Reading."
}
