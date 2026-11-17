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
 * Wake words: "reader", "speakup", and "speak up". The recogniser often writes the app's name as
 * two words, so "speak up" is matched as a pair; said on its own it is a wake word with nothing
 * after it (a brief "didn't catch that"), never "faster" or anything else.
 *
 * Prompts: while an alert or a yes/no question is up (VoiceControl.showPrompt), only its answers and
 * the always-on commands count (`promptCommands`), so "yes" can't reach the screen underneath. A
 * non-blocking prompt (a notice, an offer) only adds its answers (`extraCommands`).
 *
 * Wake word only: "goodbye" and its synonyms, and the loose yeses "sure" / "go ahead" (they can
 * open Meta AI or disconnect), so a bystander's "bye" or "sure" does nothing. "cancel" is bare only
 * inside an alert. A prompt's own answer said after its question has finished skips the echo check,
 * since the question ends "Say yes or no.".
 *
 * Settings ("natural voice on", "shorter", "disconnect"...) work on the home and camera screens.
 * Help leaves them out and offers "settings", which lists them, so help stays one breath.
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
  /// While a page is read: the next sentence; after a stop, the cut sentence again. On the first
  /// screen: go on.
  case continueOn
  /// While a page is read: the next sentence, always.
  case next
  /// While a page is read: previous sentence.
  case back
  /// After a stop: carry on from the sentence that was cut.
  case resume
  /// Yes to whatever is asked: connect on the first screen, an alert's action, a question.
  case yes
  /// Not now, skip, or no to a question.
  case no
  /// Closes a notice or an alert without taking its action.
  case ok
  /// Opens Meta AI to update the glasses, while an update is waiting.
  case update
  /// Stop reading, end the camera, stop listening, and let the screen sleep.
  case goodbye
  /// Lists the spoken settings.
  case settings
  case naturalVoiceOn
  /// "natural voice off" or "phone voice".
  case naturalVoiceOff
  case tipsOn
  case tipsOff
  /// Less detail in guidance and tips.
  case shorter
  case moreDetail
  /// Ask Meta AI for the glasses microphone.
  case glassesMic
  case replaySetup
  /// Asks first: "Disconnect your glasses? Say yes or no."
  case disconnect

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
    case .next: "next"
    case .back: "back"
    case .resume: "resume"
    case .yes: "yes"
    case .no: "not now"
    case .ok: "OK"
    case .update: "update"
    case .goodbye: "goodbye"
    case .settings: "settings"
    case .naturalVoiceOn: "natural voice on"
    case .naturalVoiceOff: "phone voice"
    case .tipsOn: "tips on"
    case .tipsOff: "tips off"
    case .shorter: "shorter"
    case .moreDetail: "more detail"
    case .glassesMic: "listen through glasses"
    case .replaySetup: "replay setup"
    case .disconnect: "disconnect"
    }
  }

  /// The spoken settings, offered on the home and camera screens and listed by "settings".
  static let settingsCommands: [VoiceCommand] = [
    .naturalVoiceOn, .naturalVoiceOff, .tipsOn, .tipsOff, .shorter, .moreDetail, .glassesMic, .replaySetup, .disconnect,
  ]
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
  /// A firmware or glasses-app update is waiting, so "update" is offered.
  var canUpdate = false
  /// A blocking prompt is up: only these (and the always-on commands) count.
  var promptCommands: [VoiceCommand]?
  /// A non-blocking prompt's answers, added to the screen's commands.
  var extraCommands: [VoiceCommand] = []
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

  private static let wakeWords: Set<String> = ["reader", "readers", "speakup", "speakups"]
  /// Wake words the recogniser writes as two words.
  private static let wakePairs: [[String]] = [["speak", "up"]]
  private static let wakeLeadIns: Set<String> = ["hey", "hi", "ok", "okay"]

  /// Every phrase belongs to one command only (VoiceCommandParserTests checks).
  static let phrases: [VoiceCommand: [String]] = [
    .read: ["read", "read this", "read that", "read it", "read aloud", "read it aloud", "read this aloud", "read text", "read the text"],
    .stop: ["stop", "pause", "quiet", "be quiet", "stop reading", "stop talking", "hush"],
    .repeatLast: ["repeat", "repeat that", "repeat this", "again", "say again", "say that again", "what did you say"],
    .status: ["status", "whats the status", "what is the status", "are you ready", "is it ready"],
    .connect: ["connect", "connect glasses", "connect my glasses", "connect the glasses"],
    .tryAgain: ["try again", "retry", "try it again", "try that again", "connect again"],
    .faster: ["faster", "speak faster", "talk faster", "speed up"],
    .slower: ["slower", "speak slower", "talk slower", "slow down"],
    .help: ["help", "what can i say", "commands", "what can you do"],
    .continueOn: ["continue", "go on", "carry on"],
    .next: ["next", "next sentence"],
    .back: ["back", "go back", "previous", "previous sentence"],
    .resume: [
      "resume", "resume reading", "keep reading", "carry on reading", "continue reading", "go on reading", "keep going", "play",
    ],
    .yes: ["yes", "yeah", "yep", "yes please", "sure", "go ahead", "allow", "allow it", "allow access", "allow camera"],
    .no: [
      "no", "nope", "not now", "no thanks", "not yet", "later", "maybe later", "skip", "skip it", "skip this", "skip setup",
      "skip for now", "cancel",
    ],
    .ok: ["ok", "okay", "ok thanks", "okay thanks", "ok thank you", "okay thank you", "got it", "dismiss", "close", "all right", "alright"],
    .update: [
      "update", "update glasses", "update my glasses", "update the glasses", "update firmware", "update the firmware",
      "install the update", "install update",
    ],
    .goodbye: ["goodbye", "good bye", "bye", "bye bye", "im done", "i am done", "im finished", "stop listening", "go to sleep"],
    .settings: ["settings", "what settings", "settings help", "what are the settings", "options"],
    .naturalVoiceOn: [
      "natural voice on", "natural voice", "use natural voice", "use the natural voice", "turn on natural voice",
      "turn natural voice on", "turn on the natural voice", "switch to natural voice", "switch to the natural voice",
    ],
    .naturalVoiceOff: [
      "natural voice off", "turn off natural voice", "turn natural voice off", "turn off the natural voice", "phone voice",
      "use phone voice", "use the phone voice", "use the phones voice", "switch to phone voice", "switch to the phone voice",
    ],
    .tipsOn: ["tips on", "turn tips on", "turn on tips", "spoken tips on", "turn on spoken tips", "turn spoken tips on"],
    .tipsOff: ["tips off", "turn tips off", "turn off tips", "spoken tips off", "turn off spoken tips", "turn spoken tips off", "no more tips"],
    .shorter: ["shorter", "be shorter", "less detail", "less detailed", "be brief", "briefer", "keep it short"],
    .moreDetail: ["more detail", "more details", "more detailed", "longer", "explain more"],
    .glassesMic: [
      "listen through glasses", "listen through my glasses", "listen through the glasses", "use glasses mic",
      "use the glasses mic", "use glasses microphone", "use the glasses microphone",
    ],
    .replaySetup: [
      "replay setup", "replay the setup", "replay set up", "redo setup", "run setup again", "setup again", "set up again",
      "start setup again",
    ],
    .disconnect: ["disconnect", "disconnect glasses", "disconnect my glasses", "disconnect the glasses"],
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

  /// Phrases a bystander could say in passing, with big effects (stop listening, open Meta AI,
  /// disconnect, skip setup): they only count after the wake word ("reader, goodbye"). Bare yes
  /// stays yes, yeah, yep, yes please, and the deliberate "allow".
  static let wakeOnlyPhrases: Set<String> = {
    var set = Set(phrases[.goodbye] ?? [])
    set.formUnion(["sure", "go ahead"])
    return set
  }()

  /// Bare only while an alert or question is up: on a screen, "cancel" from across the room would
  /// skip setup.
  static let promptOnlyBarePhrases: Set<String> = ["cancel"]

  static func parse(_ transcript: String, context: VoiceContext) -> VoiceParseResult {
    let tokens = normalize(transcript)
    guard !tokens.isEmpty else { return .ignored(.empty) }
    let (hadWake, afterWake) = stripWakeWord(tokens)

    if !hadWake, context.isSpeaking || context.requiresWakeWord { return .ignored(.needsWakeWord) }
    let matched = match(afterWake)
    // A prompt's own answer, said once its question has finished, is the user, not an echo of
    // "...Say yes or no." (which the echo check below would otherwise catch for a second or so).
    let promptAnswers = (context.promptCommands ?? []) + context.extraCommands
    let answersPrompt = matched.map { promptAnswers.contains($0.command) } ?? false
    if !(answersPrompt && !context.isSpeaking), overlaps(tokens, spoken: normalize(context.spokenText), hadWake: hadWake) {
      return .ignored(.overlapsSpeech)
    }

    guard let matched else {
      return hadWake ? .notUnderstood : .ignored(.unrecognized)
    }
    let command = matched.command
    if !hadWake {
      if wakeOnlyPhrases.contains(matched.phrase) { return .ignored(.needsWakeWord) }
      if promptOnlyBarePhrases.contains(matched.phrase), context.promptCommands == nil { return .ignored(.needsWakeWord) }
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
    if let first = rest.first, wakeWords.contains(first) { return (true, Array(rest.dropFirst())) }
    for pair in wakePairs where rest.count >= pair.count && Array(rest.prefix(pair.count)) == pair {
      return (true, Array(rest.dropFirst(pair.count)))
    }
    return (false, tokens)
  }

  /// The command for the words, peeling filler off one piece at a time and checking for a phrase
  /// after each. Checking as it goes keeps phrases that end in a filler word ("not now", "skip for
  /// now") whole.
  private static func match(_ tokens: [String]) -> (command: VoiceCommand, phrase: String)? {
    var rest = tokens
    while true {
      let phrase = rest.joined(separator: " ")
      if let command = phraseLookup[phrase] { return (command, phrase) }
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

  /// Valid on every screen, prompts included.
  static let alwaysCommands: [VoiceCommand] = [.help, .stop, .repeatLast, .faster, .slower, .goodbye]

  static func availableCommands(context: VoiceContext) -> [VoiceCommand] {
    let always = alwaysCommands
    if let prompt = context.promptCommands { return unique(prompt + always) }
    let settings: [VoiceCommand] = [.settings] + VoiceCommand.settingsCommands
    let screen: [VoiceCommand]
    switch context.screen {
    case .welcome:
      screen = [.connect, .tryAgain, .continueOn, .next, .yes, .no] + always
    case .home:
      screen = [.connect, .tryAgain, .status] + always + settings
    case .camera:
      let update: [VoiceCommand] = context.canUpdate ? [.update] : []
      let reading: [VoiceCommand] = context.hasReadSentences ? [.continueOn, .next, .back, .resume] : []
      screen = [.read, .status] + update + reading + always + settings
    }
    return unique(screen + context.extraCommands)
  }

  private static func unique(_ commands: [VoiceCommand]) -> [VoiceCommand] {
    var seen = Set<VoiceCommand>()
    return commands.filter { seen.insert($0).inserted }
  }

  /// "You can say: read, status..." for the commands valid right now. The settings are left to
  /// "settings", so this stays short.
  static func helpLine(context: VoiceContext) -> String {
    let words = availableCommands(context: context)
      .filter { $0 != .help && !VoiceCommand.settingsCommands.contains($0) }
      .map(\.phrase).joined(separator: ", ")
    let lead = context.requiresWakeWord || context.isSpeaking ? "Say reader first, then one of these" : "You can say"
    return "\(lead): \(words)."
  }

  /// The answer to "settings": the spoken settings valid here.
  static func settingsLine(context: VoiceContext) -> String {
    let available = availableCommands(context: context)
    let words = VoiceCommand.settingsCommands.filter(available.contains).map(\.phrase)
    guard !words.isEmpty else { return helpLine(context: context) }
    return "Settings you can say: \(words.joined(separator: ", "))."
  }
}
