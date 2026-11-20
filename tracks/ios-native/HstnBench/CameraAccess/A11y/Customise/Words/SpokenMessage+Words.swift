/*
 * SpokenMessage+Words - what "Your words" and "Your buttons" say. British spelling, short, and
 * every refusal says why and what to do instead.
 */

import Foundation

extension SpokenMessage {
  // MARK: Lock

  static let customiseLocked = "Settings are locked. Say unlock settings to change them."

  // MARK: Your words

  static func wordsAliasSaved(_ name: String, _ phrase: String) -> String {
    "Done. When you say \(name), I'll \(phrase)."
  }

  static func wordsMacroStarted(_ name: String) -> String {
    "Making \(name). Say the first thing it should do, like open mail reader. Say that's all when it's done, or cancel."
  }

  static func wordsMacroStepAdded(_ step: String) -> String {
    "Then \(step). Say the next thing, or that's all."
  }

  static let wordsMacroNeedsAStep = "It doesn't do anything yet. Say a command for it to do, or cancel."
  static let wordsMacroTooLong = "That's the most steps one word can have. Say that's all to finish, or cancel."
  static let wordsMacroStepRemoved = "Taken out. Say the next thing, or that's all."

  static func wordsMacroReadBack(_ macro: WordMacro) -> String {
    "\(WordsText.capitalisedFirst(macro.name)) will \(macro.spokenSteps). Shall I save it? Say yes, or no to drop it."
  }

  static func wordsMacroSaved(_ macro: WordMacro) -> String {
    "Saved. Say \(macro.name) to \(macro.spokenSteps)."
  }

  static func wordsMacroDropped(_ name: String) -> String { "Okay, I didn't save \(name)." }

  static func wordsStepNotUnderstood(_ step: String) -> String {
    "I don't know how to \(step). Say something SpeakUp already does, like open mail reader or read it all."
  }

  static func wordsForgotten(_ name: String) -> String { "I've forgotten \(name)." }

  static func wordsNotFound(_ name: String) -> String {
    "You don't have a word called \(name). Say what are my words to hear them."
  }

  static let wordsNone =
    "You haven't made any words yet. Say when I say, then your word, then what it should do. For example: when I say post, open mail reader."

  static func wordsList(aliases: [WordAlias], macros: [WordMacro]) -> String {
    var parts: [String] = []
    if !aliases.isEmpty {
      let each = aliases.map { "\($0.name) means \($0.phrase)" }
      parts.append("Your words: \(WordsText.list(each)).")
    }
    if !macros.isEmpty {
      let each = macros.map { "\($0.name) will \($0.spokenSteps)" }
      parts.append("Your macros: \(WordsText.list(each)).")
    }
    return parts.joined(separator: " ")
  }

  static func wordsMeaning(_ name: String, _ meaning: String) -> String { "\(WordsText.capitalisedFirst(name)) will \(meaning)." }

  // MARK: Name refusals

  static let wordsNameEmpty = "I didn't catch the word. Say when I say, then your word, then what it should do."

  static func wordsNameTooLong(_ name: String) -> String {
    "\(WordsText.capitalisedFirst(name)) is too long to say quickly. Choose up to four words."
  }

  static func wordsNameIsAddressWord(_ name: String) -> String {
    "I can't use \(name): it starts with my name, \(AddressWord.current). Choose another word."
  }

  static func wordsNameTaken(_ name: String, meaning: String) -> String {
    "You already use \(name) to \(meaning). Say forget \(name) first."
  }

  static func wordsNameBuiltIn(_ name: String) -> String {
    "I can't use \(name): it's already a SpeakUp command. Choose another word."
  }

  static func wordsNameSettings(_ name: String) -> String {
    "I can't use \(name): it sounds like a way to change settings. Choose another word."
  }

  static func wordsNameInTool(_ name: String, tool: ToolID) -> String {
    "I can't use \(name): it already means something in \(tool.title.lowercased()). Choose another word."
  }

  // MARK: Tools menu

  static func homeMoved(_ tool: ToolID, position: Int, count: Int) -> String {
    let place: String =
      switch position {
      case 0: "first"
      case count - 1: "last"
      default: "number \(WordsText.count(position + 1))"
      }
    return "\(tool.title) is \(place) on your tools menu now."
  }

  static func homeAlreadyThere(_ tool: ToolID) -> String { "\(tool.title) is already there." }

  static func homeHidden(_ tools: [ToolID]) -> String {
    let names = WordsText.list(tools.map(\.title))
    let verb = tools.count == 1 ? "is" : "are"
    return "\(names) \(verb) hidden from your tools menu. You can still open \(tools.count == 1 ? "it" : "them") by name. "
      + "Say show all tools to bring \(tools.count == 1 ? "it" : "them") back."
  }

  static let homeCantHideAll = "That would hide every tool. Keep at least one on the menu."

  static func homeShown(_ tools: [ToolID]) -> String {
    let names = WordsText.list(tools.map(\.title))
    return "\(names) \(tools.count == 1 ? "is" : "are") on your tools menu."
  }

  static let homeAllShown = "All your tools are on the menu again."
  static let homeNothingHidden = "All your tools are already on the menu."

  static func homeUnknownTool(_ words: String) -> String {
    "I don't know a tool called \(words). The tools are \(VoiceCommandParser.toolNames)."
  }

  // MARK: Address word

  static func addressWordSet(_ word: String) -> String {
    word == AddressWord.defaultWord
      ? "Okay, call me reader again."
      : "Okay, call me \(word) from now on. When I'm talking, say \(word) first. Try \(word), help."
  }

  static func addressWordIs(_ word: String) -> String {
    "You call me \(word). To change it, say call you, then a new name."
  }

  static let addressWordTooShort = "That name is too short for me to hear reliably. Choose a word of three letters or more."
  static let addressWordTooLong = "Choose a name of one or two words."

  static func addressWordIsCommand(_ word: String) -> String {
    "I can't use \(word) as my name: it's a word you'd also say in a command. Choose something unusual, like a name."
  }

  static func addressWordIsYourWord(_ word: String) -> String {
    "\(WordsText.capitalisedFirst(word)) is one of your own words. Forget it first, or choose another name."
  }

  static func addressWordSame(_ word: String) -> String { "You already call me \(word)." }

  // MARK: Your buttons

  static let controlsWarning =
    "Tap and hold on the side of the glasses belongs to Meta: it ends the session, so I never hear it. A single tap pauses or resumes."

  static let controlsNeedGlassesBuild =
    "Glasses buttons need the SpeakUp Beta, which works with Meta glasses. On the phone, use Back Tap or a shortcut instead."

  static func controlsSet(_ control: GlassesControl, _ action: ControlAction) -> String {
    "\(WordsText.capitalisedFirst(control.spokenName)) will \(action.spokenName) now."
  }

  static func controlsAlready(_ control: GlassesControl, _ action: ControlAction) -> String {
    "\(WordsText.capitalisedFirst(control.spokenName)) already will \(action.spokenName)."
  }

  static let controlsOn = "Glasses buttons on. Say what do my buttons do to hear them."
  static let controlsOff = "Glasses buttons off. The glasses' own button actions are back."
  static let controlsAlreadyOn = "Glasses buttons are already on."
  static let controlsAlreadyOff = "Glasses buttons are already off."

  static func controlsUnknownAction(_ words: String) -> String {
    "I can't make a button \(words). Choose look, read, repeat, stop, next, previous, status, help, a tool, your favourite tool, or one of your macros."
  }

  static func favouriteSet(_ tool: ToolID) -> String {
    "\(tool.title) is your favourite tool. Say open my favourite, or use the Open favourite tool shortcut."
  }

  static func favouriteIs(_ tool: ToolID) -> String { "Your favourite tool is \(tool.title.lowercased())." }

  static let favouriteNone = "You haven't chosen a favourite tool. Say make, then a tool's name, my favourite."
}
