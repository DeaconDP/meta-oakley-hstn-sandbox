/*
 * ReminderGrammar - what the user said to Reminders: add, list, what's due, cancel, snooze, done,
 * undo, the medicine log, a dose question (refused), and "what was I doing?"
 *
 * Pure: the words, now, a calendar and the medicine names already logged in; an intent out.
 *
 * Medicine rules (notes/value-strategy.md > 7): the log is what the user says they took, never a
 * dose. A name keeps no number or unit ("I took 2 paracetamol" logs "paracetamol"), so a number is
 * never said back. A question about how much, how many, how often, or whether to take something
 * is a dose question: the answer points to the label or the pharmacist and nothing else.
 */

import Foundation

enum ReminderIntent: Equatable, Sendable {
  enum DueRange: Equatable, Sendable { case today, tomorrow, week }

  case add(text: String, when: ReminderWhen)
  /// "Remind me to call Mum": no time heard.
  case needsTime(text: String)
  /// "Remind me at 6": nothing to remind about.
  case needsText
  case list
  case due(DueRange)
  case cancel(query: String)
  case cancelAll
  case snooze(minutes: Int)
  case done
  case undo
  /// "I took my evening pill" (at a time said, or now when nil).
  case tookMedicine(name: String, at: Date?)
  case didTake(name: String)
  case lastTook(name: String)
  case medicineLog
  case doseQuestion
  case whatWasIDoing

  /// Works from any screen, not only with Reminders open (ToolHub.route).
  var worksFromAnywhere: Bool {
    switch self {
    case .add, .needsTime, .needsText, .list, .due, .tookMedicine, .didTake, .lastTook, .medicineLog, .doseQuestion,
      .whatWasIDoing:
      true
    case .cancel, .cancelAll, .snooze, .done, .undo:
      false
    }
  }
}

enum ReminderGrammar {
  static let defaultSnoozeMinutes = 10

  // MARK: Parse

  static func parse(
    _ text: String, now: Date = Date(), calendar: Calendar = .current, knownMedicines: [String] = []
  ) -> ReminderIntent? {
    var tokens = ReminderTimeParser.tokens(text)
    tokens = stripFillers(tokens)
    let words = tokens.map(\.norm)
    guard !words.isEmpty else { return nil }
    let sentence = words.joined(separator: " ")
    let isAdd = addPrefixLength(words) != nil

    if isDoseQuestion(words, knownMedicines: knownMedicines, isReminder: isAdd) { return .doseQuestion }
    if let minutes = snoozeMinutes(words) { return .snooze(minutes: minutes) }
    if let prefix = addPrefixLength(words) {
      return addIntent(Array(tokens[prefix...]), now: now, calendar: calendar, knownMedicines: knownMedicines)
    }
    if undoPhrases.contains(sentence) { return .undo }
    if donePhrases.contains(sentence) { return .done }
    if let cancel = cancelIntent(words) { return cancel }
    if let medicine = medicineIntent(tokens, now: now, calendar: calendar, knownMedicines: knownMedicines) { return medicine }
    if whatWasIDoingPhrases.contains(sentence) { return .whatWasIDoing }
    if medicineLogPhrases.contains(sentence) { return .medicineLog }
    if let range = dueRange(words) { return .due(range) }
    if listPhrases.contains(sentence) { return .list }
    return nil
  }

  /// "undo", "cancel that": takes back the reminder just added (ToolHub, from another tool).
  static func isUndo(_ text: String) -> Bool {
    undoPhrases.contains(stripFillers(ReminderTimeParser.tokens(text)).map(\.norm).joined(separator: " "))
  }

  /// For ToolHub: does this go to Reminders from any screen?
  static func worksFromAnywhere(_ text: String) -> Bool {
    parse(text)?.worksFromAnywhere ?? false
  }

  // MARK: Phrases

  private static let leadingFillers: [[String]] = [
    ["can", "you"], ["could", "you"], ["would", "you"], ["will", "you"], ["please"], ["hey"], ["ok"], ["okay"], ["um"], ["uh"],
    ["so"], ["oh"], ["right"],
  ]
  private static let trailingFillers: [[String]] = [["please"], ["thanks"], ["thank", "you"], ["for", "me"]]

  static let undoPhrases: Set<String> = ["undo", "undo that", "undo it", "cancel that", "cancel it", "scratch that"]
  static let donePhrases: Set<String> = [
    "done", "mark done", "mark it done", "mark as done", "mark it as done", "its done", "ive done it", "i have done it",
    "i did it", "done it", "did it", "all done", "finished", "ive finished", "thats done",
  ]
  static let listPhrases: Set<String> = [
    "what reminders do i have", "what reminders have i got", "what reminders are there", "what are my reminders",
    "list reminders", "list my reminders", "read my reminders", "read me my reminders", "any reminders",
    "do i have any reminders", "have i got any reminders", "reminders", "my reminders", "show my reminders",
    "whats coming up", "what is coming up", "open reminders", "open my reminders", "open the reminders",
  ]
  static let whatWasIDoingPhrases: Set<String> = [
    "what was i doing", "what was i just doing", "what did i just do", "what was i up to", "where was i",
    "what did i do last", "what was i doing just now",
  ]
  static let medicineLogPhrases: Set<String> = [
    "medicine log", "my medicine log", "read my medicine log", "whats in my medicine log", "open medicine log",
    "open the medicine log", "open my medicine log", "what have i taken today", "what did i take today",
  ]

  private static func stripFillers(_ tokens: [ReminderToken]) -> [ReminderToken] {
    var rest = tokens
    var changed = true
    while changed {
      changed = false
      for filler in leadingFillers where rest.count > filler.count && rest.prefix(filler.count).map(\.norm) == filler {
        rest.removeFirst(filler.count)
        changed = true
      }
      for filler in trailingFillers where rest.count > filler.count && rest.suffix(filler.count).map(\.norm) == filler {
        rest.removeLast(filler.count)
        changed = true
      }
    }
    return rest
  }

  private static func starts(_ words: [String], with prefix: [String]) -> Bool {
    words.count >= prefix.count && Array(words.prefix(prefix.count)) == prefix
  }

  private static func contains(_ words: [String], phrase: [String]) -> Bool {
    guard phrase.count <= words.count else { return false }
    for start in 0...(words.count - phrase.count) where Array(words[start..<(start + phrase.count)]) == phrase {
      return true
    }
    return false
  }

  // MARK: Add

  private static let addPrefixes: [[String]] = [
    ["remind", "me"], ["set", "me", "a", "reminder"], ["set", "a", "reminder"], ["set", "reminder"], ["add", "a", "reminder"],
    ["make", "a", "reminder"], ["create", "a", "reminder"], ["new", "reminder"], ["reminder"],
  ]

  private static func addPrefixLength(_ words: [String]) -> Int? {
    for prefix in addPrefixes where starts(words, with: prefix) {
      // "Reminders" and "reminder" alone are the list or the tool's name, not a new one.
      if prefix == ["reminder"], words.count == 1 { return nil }
      return prefix.count
    }
    return nil
  }

  private static func addIntent(
    _ rest: [ReminderToken], now: Date, calendar: Calendar, knownMedicines: [String]
  ) -> ReminderIntent {
    guard let found = ReminderTimeParser.split(rest, now: now, calendar: calendar) else {
      let text = taskText(rest, knownMedicines: knownMedicines)
      return text.isEmpty ? .needsText : .needsTime(text: text)
    }
    let text = taskText(found.rest, knownMedicines: knownMedicines)
    guard !text.isEmpty else { return .needsText }
    return .add(text: text, when: found.when)
  }

  /// The words to remind about: "to"/"that"/"about" off the front, numbers and units off a
  /// medicine reminder ("take 2 pills" is "take pills").
  static func taskText(_ tokens: [ReminderToken], knownMedicines: [String]) -> String {
    var rest = tokens
    while let first = rest.first, ["to", "that", "about", "for", "i", "should", "need", "must", "have"].contains(first.norm),
      rest.count > 1 || first.norm == "to"
    {
      rest.removeFirst()
      if first.norm == "to" || first.norm == "that" || first.norm == "about" { break }
    }
    if isMedicine(rest.map(\.norm), knownMedicines: knownMedicines) {
      rest = withoutQuantities(rest)
    }
    return rest.map(\.orig).filter { !$0.isEmpty }.joined(separator: " ")
      .trimmingCharacters(in: CharacterSet(charactersIn: " .,!?;:"))
  }

  // MARK: Snooze, cancel, due

  private static func snoozeMinutes(_ words: [String]) -> Int? {
    if words.first == "snooze" {
      let rest = words.dropFirst().drop(while: { ["it", "that", "for", "the", "reminder"].contains($0) })
      if rest.isEmpty { return defaultSnoozeMinutes }
      return ReminderTimeParser.duration(rest) ?? defaultSnoozeMinutes
    }
    let sentence = words.joined(separator: " ")
    if ["remind me later", "remind me again later", "later please", "remind me again"].contains(sentence) {
      return defaultSnoozeMinutes
    }
    if starts(words, with: ["remind", "me", "again", "in"]) {
      return ReminderTimeParser.duration(words.dropFirst(4)) ?? defaultSnoozeMinutes
    }
    return nil
  }

  private static let cancelVerbs: [[String]] = [["cancel"], ["delete"], ["remove"], ["turn", "off"], ["stop"], ["clear"]]
  private static let cancelNoise: Set<String> = [
    "the", "my", "a", "reminder", "reminders", "to", "about", "for", "that", "daily", "please", "one",
  ]

  private static func cancelIntent(_ words: [String]) -> ReminderIntent? {
    guard let verb = cancelVerbs.first(where: { starts(words, with: $0) }) else { return nil }
    let rest = Array(words.dropFirst(verb.count))
    let mentionsReminder = rest.contains("reminder") || rest.contains("reminders")
    // "Stop" and "clear" alone belong to the app; only "stop the bins reminder" is ours.
    if verb == ["stop"] || verb == ["clear"] || verb == ["turn", "off"] { guard mentionsReminder else { return nil } }
    if rest.contains("all") || rest == ["everything"] { return .cancelAll }
    let query = rest.filter { !cancelNoise.contains($0) }
    if query.isEmpty { return mentionsReminder ? .undo : nil }
    return .cancel(query: query.joined(separator: " "))
  }

  private static func dueRange(_ words: [String]) -> ReminderIntent.DueRange? {
    let sentence = words.joined(separator: " ")
    let asksDue =
      words.contains("due")
      || ["what have i got this week", "whats on this week", "what is on this week", "whats coming up this week",
          "what have i got today", "whats on today", "what have i got tomorrow", "whats on tomorrow"].contains(sentence)
    guard asksDue, !words.contains("remind") else { return nil }
    if words.contains("today") { return .today }
    if words.contains("tomorrow") { return .tomorrow }
    return .week
  }

  // MARK: Medicine

  private static let medicineWords: Set<String> = [
    "pill", "pills", "tablet", "tablets", "capsule", "capsules", "medicine", "medicines", "medication", "medications", "meds",
    "dose", "doses", "dosage", "mg", "milligram", "milligrams", "microgram", "micrograms", "mcg", "ml", "inhaler", "insulin",
    "puff", "puffs", "drops", "paracetamol", "ibuprofen", "aspirin", "antibiotic", "antibiotics", "prescription", "injection",
    "jab", "patch", "vitamin", "vitamins", "painkiller", "painkillers",
  ]
  private static let unitWords: Set<String> = [
    "mg", "milligram", "milligrams", "microgram", "micrograms", "mcg", "ml", "millilitre", "millilitres", "milliliter",
    "milliliters", "gram", "grams", "g", "units", "unit", "drops", "puffs", "spoonful", "spoonfuls", "teaspoon", "teaspoons",
  ]
  private static let countWords: Set<String> = ["a", "an", "one", "two", "three", "half", "some", "another", "extra", "double", "couple"]

  static func isMedicine(_ words: [String], knownMedicines: [String]) -> Bool {
    if words.contains(where: medicineWords.contains) { return true }
    let known = Set(knownMedicines.flatMap { MedicineName.key($0) })
    return words.map(MedicineName.singular).contains(where: { known.contains($0) && !MedicineName.generic.contains($0) })
  }

  /// "how many pills can I take", "should I take another one", "what's the dose": never answered.
  static func isDoseQuestion(_ words: [String], knownMedicines: [String], isReminder: Bool) -> Bool {
    guard isMedicine(words, knownMedicines: knownMedicines) || words.contains("dose") || words.contains("dosage") else {
      return false
    }
    if words.contains(where: ["dose", "doses", "dosage", "dosing", "overdose"].contains) { return true }
    let phrases: [[String]] = [
      ["how", "many"], ["how", "much"], ["how", "often"], ["too", "many"], ["too", "much"], ["double", "up"], ["more", "than"],
    ]
    if phrases.contains(where: { contains(words, phrase: $0) }) { return true }
    if isReminder { return false }
    let questionStarts: [[String]] = [
      ["should", "i"], ["can", "i"], ["could", "i"], ["may", "i"], ["shall", "i"], ["is", "it", "ok"], ["is", "it", "okay"],
      ["is", "it", "safe"], ["am", "i", "allowed"], ["what", "if"], ["do", "i", "need"], ["is", "it", "alright"],
    ]
    if questionStarts.contains(where: { starts(words, with: $0) }) { return true }
    return words.contains(where: ["extra", "another"].contains) && !starts(words, with: ["i"]) && !starts(words, with: ["ive"])
  }

  /// Numbers and units out: a medicine line never carries a quantity.
  static func withoutQuantities(_ tokens: [ReminderToken]) -> [ReminderToken] {
    var out: [ReminderToken] = []
    var dropped = false
    for token in tokens {
      let word = token.norm
      if ReminderTimeParser.isNumber(word) || word.wholeMatch(of: #/\d+([.,]\d+)?(mg|ml|mcg|g)?/#) != nil
        || unitWords.contains(word) || ["x", "times"].contains(word) && dropped
      {
        dropped = true
        continue
      }
      if dropped, word == "of" {
        dropped = false
        continue
      }
      dropped = false
      out.append(token)
    }
    return out
  }

  private static let tookPrefixes: [[String]] = [
    ["i", "have", "just", "taken"], ["ive", "just", "taken"], ["i", "have", "taken"], ["ive", "taken"], ["i", "just", "took"],
    ["just", "took"], ["i", "took"], ["took"], ["i", "just", "had"], ["ive", "just", "had"], ["ive", "had"], ["i", "had"],
    ["log"],
  ]
  private static let didPrefixes: [[String]] = [
    ["did", "i", "take"], ["did", "i", "have"], ["have", "i", "taken"], ["have", "i", "had"], ["did", "i", "remember", "to", "take"],
    ["did", "i", "remember"],
  ]
  private static let lastPrefixes: [[String]] = [
    ["when", "did", "i", "last", "take"], ["when", "did", "i", "take"], ["when", "did", "i", "last", "have"],
    ["when", "did", "i", "have"], ["when", "was", "the", "last", "time", "i", "took"], ["when", "was", "the", "last", "time", "i", "had"],
    ["when", "was", "my", "last"], ["last", "time", "i", "took"],
  ]
  private static let errandWords: Set<String> = [
    "out", "for", "back", "off", "away", "home", "up", "walk", "bins", "bin", "dog", "kids", "car", "bus", "train", "photo",
    "photos", "picture", "shower", "bath", "nap", "break", "lunch", "breakfast", "dinner", "tea", "coffee",
  ]

  private static func medicineIntent(
    _ tokens: [ReminderToken], now: Date, calendar: Calendar, knownMedicines: [String]
  ) -> ReminderIntent? {
    let words = tokens.map(\.norm)
    if let prefix = lastPrefixes.first(where: { starts(words, with: $0) }) {
      let name = MedicineName.clean(Array(words.dropFirst(prefix.count)), trailing: ["last", "today", "yet"])
      return name.isEmpty ? nil : .lastTook(name: name)
    }
    if let prefix = didPrefixes.first(where: { starts(words, with: $0) }) {
      let name = MedicineName.clean(Array(words.dropFirst(prefix.count)), trailing: ["today", "yet", "already"])
      guard !name.isEmpty else { return nil }
      if prefix.last == "have" || prefix.last == "had" || prefix.last == "remember" {
        guard isMedicine(name.split(separator: " ").map(String.init), knownMedicines: knownMedicines) else { return nil }
      }
      return .didTake(name: name)
    }
    if let prefix = tookPrefixes.first(where: { starts(words, with: $0) }) {
      var rest = Array(words.dropFirst(prefix.count))
      var takenAt: Date?
      // "... at 7" / "at 7:30 am" at the end: when it was taken.
      if let atIndex = rest.lastIndex(of: "at"), atIndex > 0,
        let found = ReminderTimeParser.clock(in: ArraySlice(rest), at: atIndex + 1), atIndex + 1 + found.1 == rest.count
      {
        takenAt = ReminderTimeParser.pastTime(found.0, now: now, calendar: calendar)
        rest = Array(rest[..<atIndex])
      }
      let verb = prefix.last ?? ""
      let medicineSaid = isMedicine(rest, knownMedicines: knownMedicines)
      if !medicineSaid {
        // "I took the bins out" is not a medicine. "I took my metformin" is, the first time too.
        guard verb != "had", verb != "log" || rest.first == "my", rest.first == "my", rest.count <= 4,
          !rest.contains(where: errandWords.contains)
        else { return nil }
      }
      let name = MedicineName.clean(rest, trailing: ["today", "already", "earlier", "now", "just", "this", "morning", "evening", "tonight"])
      return name.isEmpty ? nil : .tookMedicine(name: name, at: takenAt)
    }
    return nil
  }
}

/// A medicine's name as the user says it, and the key two names are matched on.
enum MedicineName {
  /// Words that only say what kind of thing it is.
  static let generic: Set<String> = ["pill", "tablet", "capsule", "medicine", "medication", "med", "dose"]

  /// "my 2 evening pills today" is "evening pills".
  static func clean(_ words: [String], trailing: Set<String>) -> String {
    var rest = words
    while let last = rest.last, trailing.contains(last) { rest.removeLast() }
    while let first = rest.first,
      ["my", "the", "a", "an", "some", "of", "one", "two", "both"].contains(first) || ReminderTimeParser.isNumber(first)
        || first.wholeMatch(of: #/\d+([.,]\d+)?(mg|ml|mcg|g)?/#) != nil
        || ["mg", "milligrams", "milligram", "mcg", "micrograms", "ml", "tablets", "tablet", "capsules", "capsule"].contains(first)
          && rest.count > 1
    {
      rest.removeFirst()
    }
    let tokens = rest.map { ReminderToken(norm: $0, orig: $0) }
    return ReminderGrammar.withoutQuantities(tokens).map(\.norm).joined(separator: " ")
  }

  static func singular(_ word: String) -> String {
    if word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") { return String(word.dropLast()) }
    return word
  }

  /// "Evening pills" and "evening pill" are one key.
  static func key(_ name: String) -> [String] {
    name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
      .filter { !["my", "the", "a", "an"].contains($0) }.map(singular)
  }

  /// Same medicine: the same words, or one name inside the other ("pill" and "evening pill").
  static func matches(_ asked: String, _ logged: String) -> Bool {
    let a = key(asked)
    let b = key(logged)
    guard !a.isEmpty, !b.isEmpty else { return false }
    if a == b { return true }
    return Set(a).isSubset(of: Set(b)) || Set(b).isSubset(of: Set(a))
  }
}
