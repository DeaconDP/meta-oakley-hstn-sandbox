/*
 * SpokenMessage+HandsFree - what the app says about hands-free mode, push to talk, and the
 * navigation, connection and settings commands (notes/hands-free-mode.md)
 */

extension SpokenMessage {
  // MARK: The mode

  static let handsFreeOn = "Hands-free on. I'm listening. Say help at any time."

  static let handsFreeOff = "Hands-free off. Tap the mic button to give a command."

  /// First run with VoiceOver running: hands-free starts on, and this is said once.
  static let handsFreeOnForVoiceOver = "Hands-free is on. Say 'hands-free off' for touch only."

  static let handsFreeAlreadyOn = "Hands-free is already on."

  static let handsFreeAlreadyOff = "Hands-free is already off."

  /// Opened with the hands-free shortcut or speakup://handsfree.
  static let launchHandsFree = "Starting hands-free in SpeakUp."

  // MARK: Push to talk

  static let pushToTalkNothingHeard = "I didn't hear a command. Tap the mic to try again."

  static let pushToTalkNotUnderstood = "Sorry, I didn't catch that. Tap the mic and say help."

  // MARK: Getting around

  static func whereAmI(screen: String, state: String?) -> String {
    ["You're on \(screen).", state].compactMap { $0 }.joined(separator: " ")
  }

  static let mainMenuCamera = "Main menu. Say read, list tools, or open and a tool's name."

  static let mainMenuHome = "Main menu. Your glasses aren't connected. Say connect, or use the phone."

  static let mainMenuWelcome = "This is setup. Say phone, or connect."

  static let closeAppNeedsATouch =
    "Apps can't close themselves on iPhone. Swipe up from the bottom of the screen, or just lock the phone."

  static let settingsOpened =
    "Settings. You can say faster, slower, short answers, detailed answers, glasses display off, or hands-free off. Say close when you're done."

  static let settingsClosed = "Settings closed."

  static let readerOpen = "Reader. Hold up a page and say read."

  static func toolOpened(_ tool: ToolID) -> String { "\(tool.title)." }

  static func toolClosed(_ tool: ToolID) -> String { "\(tool.title) closed. Main menu." }

  static func toolHelp(_ tool: ToolID, _ toolLine: String) -> String {
    "\(toolLine) Say close to go back to the tools, stop to quiet it, or open and another tool's name."
  }

  static let readerNeedsGlasses = "The reader needs your glasses. Say connect first."

  // MARK: Tools

  /// The tools, one short line each, from ToolID, then how to open one.
  static let toolsList: String = {
    let tools = ToolID.allCases.map { "\($0.title): \($0.summary.lowercasedFirst)" }.joined(separator: " ")
    return "SpeakUp has six tools. \(tools) To use one, say open and its name, like open mail reader. "
      + "Say status to check the camera, or settings."
  }()

  static let toolsListNotConnected =
    "SpeakUp has three tools. Reader reads printed text aloud, once your glasses are connected. Say connect first. Status checks your glasses. Settings changes voice and answers."

  // MARK: Connection

  static let alreadyConnected = "Your glasses are already connected."

  static let notConnectedNothingToDisconnect = "Your glasses aren't connected, so there's nothing to disconnect."

  // MARK: Settings by voice

  static func verbositySet(_ verbosity: Verbosity) -> String {
    switch verbosity {
    case .short: "Short answers."
    case .normal: "Normal answers."
    case .detailed: "Detailed answers."
    }
  }

  static let glassesDisplayOn = "Glasses display on. It shows only on glasses that have a display."

  static let glassesDisplayOff = "Glasses display off. Everything is still spoken."

  /// Said once per launch when the glasses display fails. Audio carries on.
  static let glassesDisplayFailed = "The glasses display isn't working. Everything is still spoken."

  // MARK: Questions without dialogs

  /// After a question is put aloud in hands-free mode, in place of a dialog's buttons.
  static let sayYesOrNo = "Say yes or no."

  static let cameraPermissionQuestion =
    "To use the glasses camera, I'll switch to the Meta AI app so you can allow it, then come back. This needs a tap in Meta AI. Choose Allow always. Say yes to go, or no."

  static let metaAIRegistrationQuestion =
    "Meta AI wants to connect your glasses to this app. Say yes to finish in Meta AI, or no."
}

extension String {
  /// "Reads printed text" as "reads printed text", for a sentence that runs on from a name.
  fileprivate var lowercasedFirst: String {
    guard let first else { return self }
    return first.lowercased() + dropFirst()
  }
}
