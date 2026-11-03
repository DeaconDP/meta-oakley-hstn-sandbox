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
 */

import Foundation

enum VoiceCommand: String, CaseIterable, Sendable {
  case read
  case stop
  case repeatLast
  case status
  case connect
  case takePhoto
  case faster
  case slower
  case help
  /// Setup: continue / next. While a page is read: next sentence.
  case continueOn
  /// Setup: previous step. While a page is read: previous sentence.
  case back
  case skip
  case yes
  case no
  case testSpeaker

  /// The word or phrase help offers for it, and the name the UI shows as the last command.
  var phrase: String {
    switch self {
    case .read: "read"
    case .stop: "stop"
    case .repeatLast: "repeat"
    case .status: "status"
    case .connect: "connect"
    case .takePhoto: "take a photo"
    case .faster: "faster"
    case .slower: "slower"
    case .help: "help"
    case .continueOn: "continue"
    case .back: "back"
    case .skip: "skip"
    case .yes: "yes"
    case .no: "no"
    case .testSpeaker: "test the speaker"
    }
  }
}

/// Which screen commands apply to.
enum VoiceScreen: Equatable, Sendable {
  case setup(OnboardingStep)
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
    .connect: ["connect", "connect glasses", "connect my glasses", "connect the glasses", "start", "start session", "start a session", "start the session", "start camera", "start the camera", "start preview", "start the preview"],
    .takePhoto: ["take a photo", "take photo", "take a picture", "take picture", "photo", "picture"],
    .faster: ["faster", "speak faster", "talk faster", "speed up"],
    .slower: ["slower", "speak slower", "talk slower", "slow down"],
    .help: ["help", "what can i say", "commands", "what can you do"],
    .continueOn: ["continue", "next", "next step", "next sentence", "go on", "carry on", "i understand", "start guided setup", "guided setup"],
    .back: ["back", "go back", "previous", "previous step", "previous sentence"],
    .skip: ["skip", "skip this", "skip it", "skip this step", "skip step", "skip to the app", "skip setup"],
    .yes: ["yes", "yeah", "yep", "yes i heard it", "i heard it", "i heard that", "turn it on"],
    .no: ["no", "nope", "no i didnt", "i didnt hear it", "not now", "no thanks"],
    .testSpeaker: ["test the speaker", "test speaker", "speaker test", "play test", "play the test", "replay"],
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
    let (hadWake, afterWake) = stripWakeWord(tokens)

    if !hadWake, context.isSpeaking || context.requiresWakeWord { return .ignored(.needsWakeWord) }
    if overlaps(tokens, spoken: normalize(context.spokenText), hadWake: hadWake) { return .ignored(.overlapsSpeech) }

    guard let command = phraseLookup[stripFiller(afterWake).joined(separator: " ")] else {
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

  private static func stripFiller(_ tokens: [String]) -> [String] {
    var rest = tokens
    var changed = true
    while changed {
      changed = false
      for filler in leadingFiller where rest.count > filler.count && Array(rest.prefix(filler.count)) == filler {
        rest.removeFirst(filler.count)
        changed = true
      }
      for filler in trailingFiller where rest.count > filler.count && Array(rest.suffix(filler.count)) == filler {
        rest.removeLast(filler.count)
        changed = true
      }
    }
    return rest
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

  static func availableCommands(context: VoiceContext) -> [VoiceCommand] {
    let always: [VoiceCommand] = [.help, .stop, .repeatLast, .faster, .slower]
    switch context.screen {
    case .home:
      return [.connect, .status] + always
    case .camera:
      let reading: [VoiceCommand] = context.hasReadSentences ? [.continueOn, .back] : []
      return [.read, .takePhoto, .status, .connect] + reading + always
    case .setup(let step):
      return setupCommands(step) + always
    }
  }

  private static func setupCommands(_ step: OnboardingStep) -> [VoiceCommand] {
    switch step {
    case .welcome: [.continueOn, .yes, .skip, .no]
    case .voiceControl: [.yes, .no, .continueOn, .back, .skip]
    case .sounds: [.continueOn, .back, .skip]
    case .speakerTest: [.yes, .no, .testSpeaker, .continueOn, .back, .skip]
    case .verbosity: [.continueOn, .back, .skip]
    case .disclaimer: [.continueOn, .back, .skip]
    case .connect: [.connect, .continueOn, .yes, .no, .back, .skip]
    }
  }

  /// "You can say: read, take a photo, status..." for the commands valid right now.
  static func helpLine(context: VoiceContext) -> String {
    let words = availableCommands(context: context).filter { $0 != .help }.map(\.phrase).joined(separator: ", ")
    let lead = context.requiresWakeWord || context.isSpeaking ? "Say reader first, then one of these" : "You can say"
    return "\(lead): \(words)."
  }
}
