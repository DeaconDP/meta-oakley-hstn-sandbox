/*
 * VoiceCommand - what can be said, and VoiceCommandParser, which turns a transcript into a command
 *
 * Pure: transcript and context in, result out. Whole-phrase matching after filler is stripped, so
 * "I'll read this later" nearby doesn't start reading, but "please read this" does.
 *
 * Not hearing itself: while the app speaks, the mic hears the book, and the book can say "stop".
 * So while speaking only "reader, ..." counts, and anything that matches the text being spoken is
 * dropped, wake word or not. When idle, bare commands work. Unrecognised speech is ignored in
 * silence so nearby conversation doesn't trigger nagging; only "reader, ..." that isn't understood
 * gets a reply. `requiresWakeWord` asks for the wake word when idle too: VoiceOver's own speech
 * can't be detected, and a mic that can hear it would hear "Read text, button" (see VoiceControl).
 *
 * Hands-free mode (notes/hands-free-mode.md) adds navigation, connection, settings and the mode
 * switch. The toolbox's push-to-talk button uses this same grammar; a press means the user is
 * talking to the app, so `addressed` counts as the wake word.
 */

import Foundation

enum VoiceCommand: String, CaseIterable, Sendable {
  case read
  case stop
  case repeatLast
  case status
  case connect
  /// Connect again after an attempt that didn't finish. Does what connect does.
  case tryAgain
  case faster
  case slower
  case help
  /// While a page is read: next sentence. On the first screen: go on.
  case continueOn
  /// While a page is read: previous sentence.
  case back
  /// The first screen: yes, connect.
  case yes
  /// The first screen: not now, skip.
  case no
  // Getting around
  case mainMenu
  case listTools
  case openReader
  case openSettings
  /// Close settings, or go back to the main menu.
  case close
  case whereAmI
  /// iOS doesn't let an app close itself, so this says how.
  case closeApp
  case disconnect
  // Settings by voice
  case shortAnswers
  case normalAnswers
  case detailedAnswers
  case glassesDisplayOn
  case glassesDisplayOff
  case handsFreeOn
  case handsFreeOff
  // Camera source (V0 "Glasses optional", CameraSourceRouter)
  /// Read with the iPhone's camera. On the first screen: set up without glasses.
  case usePhone
  /// Read with the glasses' camera. On the first screen: connect them.
  case useGlasses
  case whichCamera
  case torchOn
  case torchOff
  // The everyday tools (ToolHub). Read text is .read ("read now") and .openReader.
  case openMail
  case openLabels
  case openWatch
  case openAsk
  case openLight

  /// The word or phrase help offers for it, and the name the UI shows as the last command.
  var phrase: String {
    switch self {
    case .read: "read"
    case .stop: "stop"
    case .repeatLast: "repeat"
    case .status: "status"
    case .connect: "connect"
    case .tryAgain: "try again"
    case .faster: "faster"
    case .slower: "slower"
    case .help: "help"
    case .continueOn: "continue"
    case .back: "back"
    case .yes: "yes"
    case .no: "not now"
    case .mainMenu: "main menu"
    case .listTools: "list tools"
    case .openReader: "open reader"
    case .openSettings: "settings"
    case .close: "close"
    case .whereAmI: "where am I"
    case .closeApp: "close the app"
    case .disconnect: "disconnect"
    case .shortAnswers: "short answers"
    case .normalAnswers: "normal answers"
    case .detailedAnswers: "detailed answers"
    case .glassesDisplayOn: "glasses display on"
    case .glassesDisplayOff: "glasses display off"
    case .handsFreeOn: "hands-free on"
    case .handsFreeOff: "hands-free off"
    case .usePhone: "use the phone"
    case .useGlasses: "use the glasses"
    case .whichCamera: "which camera"
    case .torchOn: "torch on"
    case .torchOff: "torch off"
    case .openMail: "open mail reader"
    case .openLabels: "open labels"
    case .openWatch: "watch for text"
    case .openAsk: "open ask"
    case .openLight: "light and colour"
    }
  }

  /// The tool this command opens, if it opens one. "read" opens Read text and reads at once.
  var tool: ToolID? {
    switch self {
    case .openReader, .read: .read
    case .openMail: .mail
    case .openLabels: .labels
    case .openWatch: .watch
    case .openAsk: .ask
    case .openLight: .light
    default: nil
    }
  }

  /// The command that opens `tool` without doing anything else.
  static func open(_ tool: ToolID) -> VoiceCommand {
    switch tool {
    case .read: .openReader
    case .mail: .openMail
    case .labels: .openLabels
    case .watch: .openWatch
    case .ask: .openAsk
    case .light: .openLight
    }
  }

  /// The commands that open a tool by name.
  static let openTools: [VoiceCommand] = ToolID.allCases.map(open)
}

/// Which screen commands apply to.
enum VoiceScreen: Equatable, Sendable {
  /// The one first-run screen (OnboardingView).
  case welcome
  case home
  case camera
}

struct VoiceContext: Equatable, Sendable {
  var screen: VoiceScreen
  /// Announcer.isSpeaking.
  var isSpeaking = false
  /// What is being said, queued or just finished (Announcer.textBeingSpoken).
  var spokenText = ""
  /// Bare commands aren't safe right now even when idle (see the file comment).
  var requiresWakeWord = false
  /// A page has been read, so "next" and "back" move between its sentences.
  var hasReadSentences = false
  /// Hands-free is on. Only changes which mode switch help offers.
  var handsFree = false
  /// Push to talk: the user pressed the mic, so what is heard is for the app, as with the wake word.
  var addressed = false
  /// A yes-or-no question is waiting (VoiceControl.ask), so yes, no and continue work here too.
  var awaitingAnswer = false
  /// This build can use Meta glasses. The App Store build (SPEAKUP_NO_DAT) can't, so help and tips
  /// don't offer connect or use the glasses there.
  var glassesSupported = GlassesSupport.isBuiltIn
}

enum VoiceParseResult: Equatable, Sendable {
  case command(VoiceCommand)
  /// "reader, ..." that isn't a command valid here. Say so, briefly.
  case notUnderstood
  case ignored(IgnoreReason)

  enum IgnoreReason: Equatable, Sendable {
    case empty
    case needsWakeWord
    case overlapsSpeech
    case unrecognized
    case unavailableHere
  }
}

enum VoiceCommandParser {
  static let wakeWord = "reader"

  private static let wakeWords: Set<String> = ["reader", "readers"]
  private static let wakeLeadIns: Set<String> = ["hey", "hi", "ok", "okay"]

  private static let phrases: [VoiceCommand: [String]] = [
    .read: ["read", "read this", "read that", "read it", "read aloud", "read it aloud", "read this aloud", "read text", "read the text"],
    .stop: ["stop", "pause", "quiet", "be quiet", "stop reading", "stop talking", "hush"],
    .repeatLast: ["repeat", "repeat that", "repeat this", "again", "say again", "say that again", "what did you say"],
    .status: ["status", "whats the status", "what is the status", "are you ready", "is it ready"],
    .connect: ["connect", "connect glasses", "connect my glasses", "connect the glasses"],
    .tryAgain: ["try again", "retry", "try it again", "try that again", "connect again"],
    .faster: ["faster", "speak faster", "talk faster", "speed up"],
    .slower: ["slower", "speak slower", "talk slower", "slow down"],
    .help: ["help", "what can i say", "commands", "what can you do"],
    .continueOn: ["continue", "next", "next sentence", "go on", "carry on"],
    .back: ["back", "go back", "previous", "previous sentence"],
    .yes: ["yes", "yeah", "yep", "yes please"],
    .no: ["no", "nope", "not now", "no thanks", "not yet", "later", "maybe later", "skip", "skip it", "skip this", "skip setup", "skip for now"],
    .mainMenu: ["main menu", "menu", "home", "go home", "home screen", "go to the main menu", "go to main menu"],
    .listTools: [
      "list tools", "what tools are there", "what tools do you have", "tools", "list features", "what features are there",
      "features", "what can this app do",
    ],
    .openReader: ["open reader", "open the reader", "open read text", "open reading"] + ToolID.read.openPhrases.filter { $0 != "read text" },
    .openMail: ToolID.mail.openPhrases + ["open mail", "open the mail reader", "open my mail", "read the letter", "read a letter"],
    .openLabels: ToolID.labels.openPhrases + [
      "open labels and barcodes", "labels and barcodes", "open the labels", "scan barcode", "scan a label", "barcode", "barcodes",
    ],
    .openWatch: ToolID.watch.openPhrases + ["open watch", "watch for a word", "watch for words"],
    .openAsk: ToolID.ask.openPhrases + ["open ask about the text", "ask about it", "ask a question"],
    .openLight: ToolID.light.openPhrases + [
      "open light", "open light and color", "light and color", "what color is this", "open colour", "open color",
      "is the light on or off", "is there a light on",
    ],
    .openSettings: ["settings", "open settings", "open the settings", "show settings"],
    .close: ["close", "close this", "close settings", "close the settings", "done"],
    .whereAmI: ["where am i", "what screen is this", "what screen am i on", "where are we"],
    .closeApp: ["close the app", "close app", "quit", "quit the app", "exit the app", "close speakup", "quit speakup"],
    .disconnect: ["disconnect", "disconnect glasses", "disconnect my glasses", "disconnect the glasses"],
    .shortAnswers: ["short answers", "shorter answers", "be brief", "brief answers"],
    .normalAnswers: ["normal answers", "medium answers"],
    .detailedAnswers: ["detailed answers", "long answers", "more detail", "longer answers"],
    .glassesDisplayOn: ["glasses display on", "turn on the glasses display", "turn the glasses display on", "display on"],
    .glassesDisplayOff: ["glasses display off", "turn off the glasses display", "turn the glasses display off", "display off"],
    .handsFreeOn: [
      "hands free on", "handsfree on", "start hands free", "start handsfree", "voice mode", "hands free mode", "handsfree mode",
      "turn on hands free", "turn hands free on",
    ],
    .handsFreeOff: [
      "hands free off", "handsfree off", "touch mode", "stop listening for good", "stop hands free", "turn off hands free",
      "turn hands free off", "touch only",
    ],
    .usePhone: [
      "phone", "use the phone", "use phone", "use my phone", "use the phone camera", "use my phones camera", "phone camera",
      "use the iphone", "use my iphone", "use the iphone camera", "use my iphones camera", "iphone camera", "switch to the phone",
      "switch to the phone camera",
    ],
    .useGlasses: [
      "use the glasses", "use glasses", "use my glasses", "use the glasses camera", "glasses camera", "switch to the glasses",
      "switch to the glasses camera",
    ],
    .whichCamera: [
      "which camera", "which camera is on", "which camera am i using", "what camera", "what camera am i using",
      "which camera is it",
    ],
    .torchOn: ["torch on", "turn on the torch", "turn the torch on", "flashlight on", "turn on the flashlight", "light on", "turn on the light"],
    .torchOff: [
      "torch off", "turn off the torch", "turn the torch off", "flashlight off", "turn off the flashlight", "light off",
      "turn off the light",
    ],
  ]

  private static let phraseLookup: [String: VoiceCommand] = {
    var lookup: [String: VoiceCommand] = [:]
    for (command, list) in phrases {
      for phrase in list { lookup[phrase] = command }
    }
    return lookup
  }()

  private static let leadingFiller: [[String]] = [
    ["can", "you"], ["could", "you"], ["would", "you"], ["will", "you"], ["i", "want", "to"], ["i", "would", "like", "to"],
    ["id", "like", "to"], ["i", "want", "you", "to"], ["please"], ["just"], ["now"], ["um"], ["uh"], ["er"], ["hey"], ["ok"],
    ["okay"], ["so"], ["lets"],
  ]
  private static let trailingFiller: [[String]] = [["thank", "you"], ["for", "me"], ["please"], ["now"], ["thanks"]]

  // MARK: Parse

  static func parse(_ transcript: String, context: VoiceContext) -> VoiceParseResult {
    let tokens = normalize(transcript)
    guard !tokens.isEmpty else { return .ignored(.empty) }
    let (saidWake, afterWake) = stripWakeWord(tokens)
    let hadWake = saidWake || context.addressed

    if !hadWake, context.isSpeaking || context.requiresWakeWord { return .ignored(.needsWakeWord) }
    if overlaps(tokens, spoken: normalize(context.spokenText), hadWake: hadWake) { return .ignored(.overlapsSpeech) }

    guard let command = match(afterWake) else {
      return hadWake ? .notUnderstood : .ignored(.unrecognized)
    }
    guard availableCommands(context: context).contains(command) else {
      return hadWake ? .notUnderstood : .ignored(.unavailableHere)
    }
    return .command(command)
  }

  /// Lowercased words with punctuation gone and apostrophes closed up ("what's" is "whats").
  static func normalize(_ text: String) -> [String] {
    let closed = text.lowercased().replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")
    return closed.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
  }

  private static func stripWakeWord(_ tokens: [String]) -> (Bool, [String]) {
    var rest = tokens[...]
    while let first = rest.first, wakeLeadIns.contains(first) { rest = rest.dropFirst() }
    guard let first = rest.first, wakeWords.contains(first) else { return (false, tokens) }
    return (true, Array(rest.dropFirst()))
  }

  /// The command for the words, peeling filler off one piece at a time and checking for a phrase
  /// after each. Checking as it goes keeps phrases that end in a filler word ("not now", "skip for
  /// now") whole.
  private static func match(_ tokens: [String]) -> VoiceCommand? {
    var rest = tokens
    while true {
      if let command = phraseLookup[rest.joined(separator: " ")] { return command }
      guard let shorter = stripOneFiller(rest) else { return nil }
      rest = shorter
    }
  }

  /// One leading filler removed, or else one trailing filler. nil if there is none to remove.
  private static func stripOneFiller(_ tokens: [String]) -> [String]? {
    for filler in leadingFiller where tokens.count > filler.count && Array(tokens.prefix(filler.count)) == filler {
      return Array(tokens.dropFirst(filler.count))
    }
    for filler in trailingFiller where tokens.count > filler.count && Array(tokens.suffix(filler.count)) == filler {
      return Array(tokens.dropLast(filler.count))
    }
    return nil
  }

  /// Did the mic just hear the app? With the wake word, only an exact run in the spoken text counts
  /// ("reader stop" when the book says "the reader stopped" is still the user). Without it the
  /// recogniser's slips matter more, so most of the words in a run is enough for three or more.
  private static func overlaps(_ tokens: [String], spoken: [String], hadWake: Bool) -> Bool {
    guard !spoken.isEmpty else { return false }
    let run = longestRun(of: tokens, in: spoken)
    if hadWake || tokens.count < 3 { return run == tokens.count }
    return Double(run) / Double(tokens.count) >= 0.6
  }

  private static func longestRun(of tokens: [String], in spoken: [String]) -> Int {
    var best = 0
    var previous = [Int](repeating: 0, count: spoken.count + 1)
    for token in tokens {
      var row = [Int](repeating: 0, count: spoken.count + 1)
      for (index, word) in spoken.enumerated() where word == token {
        row[index + 1] = previous[index] + 1
        best = max(best, row[index + 1])
      }
      previous = row
    }
    return best
  }

  // MARK: What's valid where

  /// Speech control, the same on every screen.
  static let speechCommands: [VoiceCommand] = [.help, .stop, .repeatLast, .faster, .slower]
  /// Getting around, the same on every screen.
  static let navigationCommands: [VoiceCommand] = [.mainMenu, .listTools, .whereAmI, .closeApp]
  /// Settings by voice, the same on every screen.
  static let settingsCommands: [VoiceCommand] = [
    .shortAnswers, .normalAnswers, .detailedAnswers, .glassesDisplayOn, .glassesDisplayOff, .handsFreeOn, .handsFreeOff,
  ]

  /// What this screen adds to the commands that work everywhere.
  static func screenCommands(context: VoiceContext) -> [VoiceCommand] {
    let answers: [VoiceCommand] = context.awaitingAnswer ? [.yes, .no, .continueOn] : []
    switch context.screen {
    case .welcome:
      return [.usePhone, .connect, .useGlasses, .tryAgain, .continueOn, .yes, .no]
    case .home:
      return [.connect, .usePhone, .tryAgain, .status, .disconnect, .openReader, .back, .close] + answers
    case .camera:
      let reading: [VoiceCommand] = context.hasReadSentences ? [.continueOn] : []
      let camera: [VoiceCommand] = [.whichCamera, .usePhone, .useGlasses, .torchOn, .torchOff]
      return [.read, .status, .tryAgain, .openReader, .openSettings, .back, .close, .connect, .disconnect] + camera + reading + answers
        + VoiceCommand.openTools
    }
  }

  /// "read text, mail reader, labels, watch for text, ask, or light and colour".
  static let toolNames: String = {
    let names = ["read text", "mail reader", "labels", "watch for text", "ask", "light and colour"]
    return names.dropLast().joined(separator: ", ") + ", or " + names.last!
  }()

  /// The words a tool should get: the transcript with any "reader, ..." taken off, or nil when it
  /// isn't for the app (the wake word was needed, or the mic heard the app's own speech). The same
  /// gates as parse(_:context:), for tools that have their own phrases (ToolHub).
  static func addressedText(_ transcript: String, context: VoiceContext) -> String? {
    let tokens = normalize(transcript)
    guard !tokens.isEmpty else { return nil }
    let (saidWake, afterWake) = stripWakeWord(tokens)
    let hadWake = saidWake || context.addressed
    if !hadWake, context.isSpeaking || context.requiresWakeWord { return nil }
    if overlaps(tokens, spoken: normalize(context.spokenText), hadWake: hadWake) { return nil }
    guard saidWake else { return transcript }
    guard !afterWake.isEmpty else { return nil }
    return afterWake.joined(separator: " ")
  }

  static func availableCommands(context: VoiceContext) -> [VoiceCommand] {
    var seen = Set<VoiceCommand>()
    return (screenCommands(context: context) + speechCommands + navigationCommands + settingsCommands)
      .filter { seen.insert($0).inserted }
  }

  /// What help says, in short groups: this screen, getting around, speech, settings. Only the mode
  /// switch that would change something is offered.
  static func helpLine(context: VoiceContext) -> String {
    let quiet: Set<VoiceCommand> = [
      .back, .close, .yes, .no, .continueOn, .tryAgain, .disconnect, .openReader, .useGlasses, .torchOff,
    ]
    let glassesOnly: Set<VoiceCommand> = [.connect, .useGlasses, .disconnect, .glassesDisplayOn, .glassesDisplayOff]
    var here = screenCommands(context: context)
      .filter { !quiet.contains($0) && !VoiceCommand.openTools.contains($0) }
      .filter { context.glassesSupported || !glassesOnly.contains($0) }
      .map(\.phrase)
    if context.screen == .welcome { here.append(VoiceCommand.no.phrase) }
    if context.hasReadSentences { here += ["next", "back"] }
    if context.awaitingAnswer { here += ["yes", "no"] }
    let mode: VoiceCommand = context.handsFree ? .handsFreeOff : .handsFreeOn
    let settings: [VoiceCommand] = context.glassesSupported ? [.shortAnswers, .glassesDisplayOff, mode] : [.shortAnswers, .detailedAnswers, mode]
    var groups = [
      "Here: \(here.joined(separator: ", ")).",
      "Anywhere: \([VoiceCommand.mainMenu, .listTools, .whereAmI].map(\.phrase).joined(separator: ", ")).",
      "Speech: \([VoiceCommand.stop, .repeatLast, .faster, .slower].map(\.phrase).joined(separator: ", ")).",
      "Settings: \(settings.map(\.phrase).joined(separator: ", ")).",
    ]
    if screenCommands(context: context).contains(.openMail) {
      groups.insert("Tools: say open, then \(toolNames).", at: 1)
    }
    let lead = context.requiresWakeWord || context.isSpeaking ? "Say reader first, then one of these." : "You can say these."
    return ([lead] + groups).joined(separator: " ")
  }
}
