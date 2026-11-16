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
    }
  }
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

  static func availableCommands(context: VoiceContext) -> [VoiceCommand] {
    let always: [VoiceCommand] = [.help, .stop, .repeatLast, .faster, .slower]
    switch context.screen {
    case .welcome:
      return [.connect, .tryAgain, .continueOn, .yes, .no] + always
    case .home:
      return [.connect, .tryAgain, .status] + always
    case .camera:
      let reading: [VoiceCommand] = context.hasReadSentences ? [.continueOn, .back] : []
      return [.read, .status] + reading + always
    }
  }

  /// "You can say: read, status..." for the commands valid right now.
  static func helpLine(context: VoiceContext) -> String {
    let words = availableCommands(context: context).filter { $0 != .help }.map(\.phrase).joined(separator: ", ")
    let lead = context.requiresWakeWord || context.isSpeaking ? "Say reader first, then one of these" : "You can say"
    return "\(lead): \(words)."
  }
}
