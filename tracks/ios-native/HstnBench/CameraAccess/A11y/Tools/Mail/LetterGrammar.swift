/*
 * LetterGrammar - "deal with this letter": reminders, explanations and the letters log, by voice
 *
 * Inside the mail reader, before MailGrammar: "remind me three days before", "remind me on
 * Friday", "remind me the day before", "cancel the reminder", "explain this letter", "what does
 * this mean", "explain online", "explain in Polish", "explain in my language", "my letters",
 * "what letters do I have", "read the letter from Northgate", "delete that letter", "forget all
 * letters", "export my letters". "yes" and "no" are only taken when the tool has just asked
 * something (MailTool decides; the parser just reports them).
 *
 * Same matching as MailGrammar: normalised words, the whole phrase must match, filler peeled off
 * the ends. Phrases with a value (a number of days, a weekday, a sender, a language) are matched
 * with one capture. Pure Swift.
 */

import Foundation

enum ExplainMode: Equatable, Sendable {
  /// Fixed rules on the phone.
  case onDevice
  /// The AI explanation, in English.
  case online
  /// The AI explanation in a language; nil means the phone's language.
  case language(String?)
}

enum LetterVoiceCommand: Equatable, Sendable {
  case remind(LetterReminderChoice)
  case cancelReminder
  case explain(ExplainMode)
  /// "explain in Klingon": a language it doesn't know, as said.
  case unknownLanguage(String)
  case myLetters
  case readSaved(String)
  case deleteThat
  case forgetAll
  case export
  case yes
  case no
}

enum LetterGrammar {
  private static let it = "(?:it|this|that|this letter|the letter|that letter|this one|that one)"
  private static let numbers: [String: Int] = [
    "one": 1, "a": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
    "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
  ]
  private static let weekdays: [String: Int] = [
    "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7,
  ]

  private static let remindLead = "(?:(?:yes|yeah|yes please) )?(?:(?:please )?remind me|set (?:a|the) reminder|give me a reminder|a reminder)"
  private static let remindDays = MailRegex("\(remindLead) (\\w+) (day|days|week|weeks) (?:before|ahead|early|earlier)(?: (?:it|the deadline|the date|its due|the appointment))?")
  private static let remindDayBefore = MailRegex("\(remindLead) (?:the|a|one) day (?:before|ahead|early)(?: (?:it|the deadline|the date|the appointment))?")
  private static let remindWeekday = MailRegex("\(remindLead) (?:on )?(?:the )?(?:this |next )?(sunday|monday|tuesday|wednesday|thursday|friday|saturday)")
  private static let remindOnTheDay = MailRegex("\(remindLead) on the (?:day|date)(?: (?:itself|its due))?")
  private static let remindPlain = MailRegex(
    "\(remindLead)(?: (?:about|of) \(it))?(?: before the (?:deadline|date|appointment))?|(?:i want|id like) a reminder|yes remind me")
  private static let cancel = MailRegex(
    "(?:cancel|delete|remove|stop|turn off) (?:the|that|my|this letters?) reminder|(?:dont|do not) remind me(?: about (?:it|this|that))?|no reminder")

  private static let explainLanguage = MailRegex(
    "(?:explain|translate) (?:\(it) )?(?:in|into) (\\w+(?: \\w+)?)|(?:explain|translate) (?:\(it) )?(?:to me )?in (\\w+(?: \\w+)?)")
  private static let explainOnline = MailRegex(
    "explain (?:\(it) )?(?:online|with ai|using ai|in more detail|in detail|properly)|(?:an |give me an )?ai explanation|ask ai to explain(?: \(it))?|explain more")
  private static let explainOnDevice = MailRegex(
    "explain(?: \(it))?(?: to me)?|what does (?:it|this|that|this letter|the letter) mean|"
      + "what (?:is|does) (?:it|this|this letter) (?:asking(?: for)?|want)|what (?:do|should) i (?:do|need to do)(?: (?:about|with) \(it))?|"
      + "what does (?:it|this letter|the letter) want(?: me to do)?|i dont understand(?: \(it))?|(?:in )?plain english|put it simply")

  private static let myLetters = MailRegex(
    "(?:my|the|saved|list(?: my)?|show(?: me)?(?: my)?|open(?: my)?) letters|what letters (?:do i have|have i got|are saved|have i saved)|"
      + "(?:list|read) (?:my|the) (?:saved )?letters|letters log|my letters log|what letters")
  private static let readSaved = MailRegex(
    "(?:read|open|find|show) (?:me )?(?:the|my) (?:saved )?letter from (.+)|what did the letter from (.+) say|(?:read|open) (?:the )?(.+?) letter")
  private static let deleteThat = MailRegex("(?:delete|remove|forget|bin) (?:that|this|the) (?:saved )?letter|(?:delete|remove|forget) (?:it|that)")
  private static let forgetAll = MailRegex("(?:forget|delete|remove|clear|erase) (?:all|all of|all my|every|everything in)(?: the| my)? letters?(?: log)?|clear (?:my |the )?letters(?: log)?|delete my letters")
  private static let export = MailRegex("(?:export|share|send|save) (?:my|the|all my|all the) letters(?: log)?(?: as (?:text|csv|a spreadsheet))?|export(?: letters)?")
  private static let yes = MailRegex("yes|yeah|yep|yes please|go ahead|do it|ok|okay|sure|yes forget them|yes delete them|yes forget all letters")
  private static let no = MailRegex("no|nope|no thanks|no thank you|not now|cancel|keep them|dont")

  /// The command, or nil (then MailGrammar has a go).
  static func parse(_ transcript: String) -> LetterVoiceCommand? {
    for phrase in MailGrammar.phrases(transcript) {
      if let command = match(phrase) { return command }
    }
    return nil
  }

  private static func match(_ p: String) -> LetterVoiceCommand? {
    if let m = remindDays.wholeMatch(p), let word = m.group(1, in: p), let n = numbers[word] ?? Int(word) {
      let unit = m.group(2, in: p) ?? "days"
      return .remind(.daysBefore(unit.hasPrefix("week") ? n * 7 : n))
    }
    if remindDayBefore.matchesWhole(p) { return .remind(.daysBefore(1)) }
    if let m = remindWeekday.wholeMatch(p), let day = m.group(1, in: p).flatMap({ weekdays[$0] }) { return .remind(.weekday(day)) }
    if remindOnTheDay.matchesWhole(p) { return .remind(.onTheDay) }
    if cancel.matchesWhole(p) { return .cancelReminder }
    if remindPlain.matchesWhole(p) { return .remind(.suggested) }

    if explainOnline.matchesWhole(p) { return .explain(.online) }
    if let m = explainLanguage.wholeMatch(p) {
      let said = (m.group(1, in: p) ?? m.group(2, in: p) ?? "").trimmed
      if ["plain english", "simple english", "plain words", "simple words", "english"].contains(said) { return .explain(.onDevice) }
      if ["my language", "my own language", "my first language", "my mother tongue"].contains(said) { return .explain(.language(nil)) }
      if ["more detail", "detail", "full", "depth"].contains(said) { return .explain(.online) }
      if let name = LetterLanguages.names[said] { return .explain(.language(name)) }
      return .unknownLanguage(said)
    }
    if explainOnDevice.matchesWhole(p) { return .explain(.onDevice) }

    if forgetAll.matchesWhole(p) { return .forgetAll }
    if deleteThat.matchesWhole(p) { return .deleteThat }
    if export.matchesWhole(p) { return .export }
    if myLetters.matchesWhole(p) { return .myLetters }
    if let m = readSaved.wholeMatch(p) {
      let name = (m.group(1, in: p) ?? m.group(2, in: p) ?? m.group(3, in: p) ?? "").trimmed
      // "read the letter" alone, or "read this letter", is MailGrammar's.
      guard !name.isEmpty, !["this", "that", "the", "my", "next", "new", "whole", "full"].contains(name) else { return nil }
      return .readSaved(name)
    }
    if yes.matchesWhole(p) { return .yes }
    if no.matchesWhole(p) { return .no }
    return nil
  }
}
