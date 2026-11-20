/*
 * WordsUnderstanding - is this something SpeakUp already understands, and may this be a new word?
 *
 * A step of a macro, or what an alias stands for, must be a phrase the app's own grammar
 * (VoiceCommandParser, on any screen) or a tool's grammar (mail, labels, light, watch, ask)
 * understands. A new name must not be one of those, nor a settings phrase (ours, the settings
 * core's, the ears'), nor the address word, nor a word the user already has. Every refusal says why.
 */

import Foundation

@MainActor
enum WordsUnderstanding {
  /// Contexts that between them allow every VoiceCommand: welcome, home and camera, with a question
  /// waiting and sentences read.
  private static let everyScreen: [VoiceContext] = [VoiceScreen.welcome, .home, .camera].map {
    VoiceContext(screen: $0, hasReadSentences: true, addressed: true, awaitingAnswer: true, glassesSupported: true)
  }

  /// The app command these words are, on any screen, or nil.
  static func builtInCommand(_ phrase: String) -> VoiceCommand? {
    for context in everyScreen {
      if case .command(let command) = VoiceCommandParser.parse(phrase, context: context) { return command }
    }
    return nil
  }

  /// The tool whose own grammar understands these words, or nil.
  static func toolUnderstanding(_ phrase: String) -> ToolID? {
    if MailGrammar.parse(phrase) != nil { return .mail }
    if LabelsGrammar.parse(phrase) != nil { return .labels }
    if LightGrammar.parse(phrase) != nil { return .light }
    if WatchGrammar.opens(phrase) != nil || WatchGrammar.parse(phrase) != nil { return .watch }
    if AskGrammar.isQuestion(phrase) { return .ask }
    return nil
  }

  /// Something the app or a tool already does when said.
  static func understands(_ phrase: String) -> Bool {
    let words = WordsText.phrase(phrase)
    guard !words.isEmpty else { return false }
    return builtInCommand(words) != nil || toolUnderstanding(words) != nil
  }

  // MARK: Phrases that belong to settings

  /// Whole phrases the settings grammars use (the core's, the ears', ours).
  static let reservedPhrases: Set<String> = [
    "undo", "put it back", "keep that", "lock settings", "unlock settings", "whats my setup", "what is my setup",
    "save as profile", "clear speech", "i use mono", "someones talking to me", "someone is talking to me", "carry on",
    "move it left", "move it right", "balance", "louder", "quieter", "earcons on", "earcons off",
    "what are my words", "show all tools", "what do my buttons do", "thats all", "thats it", "cancel", "never mind",
  ]

  /// First words that start a settings phrase ("reset speech", "switch to reading", "when I say ...").
  static let reservedFirstWords: Set<String> = [
    "when", "forget", "what", "whats", "put", "move", "hide", "show", "call", "change", "make", "set", "favourite",
    "favorite", "buttons", "then", "reset", "switch", "save", "earcons", "earcon", "louder", "quieter", "balance",
    "undo", "keep", "lock", "unlock", "clear", "someone", "someones", "carry", "run", "turn", "glasses",
  ]

  // MARK: Checks

  /// Why `name` can't be a new word or macro, or nil if it can. A word already in use must be
  /// forgotten first.
  static func problem(withName name: String, in settings: WordsSettings) -> String? {
    let tokens = name.split(separator: " ").map(String.init)
    let spoken = name
    guard !tokens.isEmpty, name.count >= 2 else { return SpokenMessage.wordsNameEmpty }
    if tokens.count > 4 { return SpokenMessage.wordsNameTooLong(spoken) }
    if AddressWord.length(atStartOf: tokens[...]) != nil {
      return SpokenMessage.wordsNameIsAddressWord(spoken)
    }
    if let alias = settings.alias(named: name) { return SpokenMessage.wordsNameTaken(spoken, meaning: alias.phrase) }
    if let macro = settings.macro(named: name) { return SpokenMessage.wordsNameTaken(spoken, meaning: macro.spokenSteps) }
    if builtInCommand(name) != nil { return SpokenMessage.wordsNameBuiltIn(spoken) }
    if reservedPhrases.contains(name) || reservedFirstWords.contains(tokens[0]) {
      return SpokenMessage.wordsNameSettings(spoken)
    }
    if let tool = toolUnderstanding(name) { return SpokenMessage.wordsNameInTool(spoken, tool: tool) }
    return nil
  }

  /// Why `word` can't be the address word, or nil if it can.
  static func problem(withAddressWord word: String, in settings: WordsSettings) -> String? {
    let tokens = word.split(separator: " ").map(String.init)
    guard !tokens.isEmpty, word.count >= 3 else { return SpokenMessage.addressWordTooShort }
    if tokens.count > 2 { return SpokenMessage.addressWordTooLong }
    if tokens.contains(where: { $0.allSatisfy(\.isNumber) }) { return SpokenMessage.addressWordTooShort }
    if word == AddressWord.defaultWord { return nil }
    if commonWords.contains(tokens[0]) || commandLeadWords.contains(tokens[0]) || builtInCommand(word) != nil {
      return SpokenMessage.addressWordIsCommand(word)
    }
    if settings.alias(named: word) != nil || settings.macro(named: word) != nil
      || settings.aliases.contains(where: { $0.name.hasPrefix(word + " ") })
      || settings.macros.contains(where: { $0.name.hasPrefix(word + " ") })
    {
      return SpokenMessage.addressWordIsYourWord(word)
    }
    return nil
  }

  /// The first word of every built-in phrase. An address word that is one of these would eat the
  /// start of a command ("stop" as a name, then "stop reading").
  static let commandLeadWords: Set<String> = {
    var words = Set<String>()
    for command in VoiceCommand.allCases {
      if let first = VoiceCommandParser.normalize(command.phrase).first { words.insert(first) }
    }
    for tool in ToolID.allCases {
      for phrase in tool.openPhrases {
        if let first = VoiceCommandParser.normalize(phrase).first { words.insert(first) }
      }
    }
    return words.union([
      "read", "stop", "pause", "quiet", "hush", "repeat", "again", "say", "next", "previous", "go", "speak", "talk",
      "slow", "speed", "skip", "later", "menu", "home", "tools", "features", "quit", "exit", "torch", "flashlight",
      "phone", "iphone", "scan", "barcode", "barcodes", "is", "how", "who", "tell", "find", "look", "keep", "start",
    ])
  }()

  /// Words too ordinary to mean "this is for the app".
  static let commonWords: Set<String> = Set([
    "a", "an", "the", "i", "me", "my", "you", "your", "we", "it", "this", "that", "and", "or", "but", "to", "of", "in",
    "on", "at", "for", "with", "yes", "no", "ok", "okay", "hey", "hi", "hello", "please", "thanks", "so", "um", "uh",
    "er", "now", "just", "can", "could", "would", "will", "then", "there", "here", "what", "when", "where", "why",
  ]).union(reservedFirstWords)
}
