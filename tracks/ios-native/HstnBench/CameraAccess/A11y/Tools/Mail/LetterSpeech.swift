/*
 * LetterSpeech - what the mail reader says about a letter
 *
 * Port of the Android LetterSpeech.kt, same wording. The short summary ("A bill from Northgate
 * Energy, for Mrs Jane Patel. ... Amount due: £84.17, by 24 November 2026."), the envelope line,
 * and the answers to "who's it from", "how much", "when is it due", "is it junk", "what's the
 * reference". Unsure or conflicting amounts are never spoken as figures: the line asks for a
 * closer look instead. Reference numbers are spelled out one character at a time. Added on iOS:
 * the scam-sign hint and "is it a scam", which never call a letter genuine. English only for
 * now, like Read text's guidance. Pure Swift.
 */

import Foundation

enum LetterSpeech {
  static let unsureAmount =
    "There's an amount to pay, but I can't read it for sure. Hold the letter a little closer and keep it still, then say how much."
  static let conflictingAmounts =
    "I can see two different amounts to pay, so I can't say which is right. Hold the letter a little closer, then say how much."
  static let notSureFigure = "an amount I can't read for sure"
  static let scamAdvice = "Check with someone you trust before you pay or reply."
  /// Never "it's genuine" or "it's safe": the rules can only find signs, not rule them out.
  static let noScamSigns =
    "No scam signs found. That doesn't prove a letter is safe, so if you're unsure, check with someone you trust."

  static func kindPhrase(_ letter: Letter) -> String { kindPhrase(kind: letter.kind) }

  static func kindPhrase(kind: LetterKind) -> String {
    switch kind {
    case .bill: "a bill"
    case .bank: "a letter from a bank"
    case .official: "an official letter"
    case .medical: "a medical letter"
    case .personal: "a personal letter"
    case .advert: "an advert, probably junk mail"
    case .unknown: "a letter"
    }
  }

  static func summary(_ letter: Letter) -> String {
    if letter.isEnvelope { return envelope(letter) }
    var parts: [String] = []
    var who = letter.pages.count > 1 ? "\(letter.pages.count) pages. " : ""
    who += kindPhrase(letter).capitalisedFirst
    if let sender = letter.sender { who += " from \(sender)" }
    if let to = letter.recipient ?? letter.salutation { who += ", for \(to)" }
    who += "."
    if letter.sender == nil { who += " I can't see who it's from." }
    parts.append(who)
    if let date = letter.date { parts.append("Dated \(date.spoken()).") }
    if let subject = letter.subject {
      parts.append("About: \(subject.trimmingTrailing(["."])).")
    } else if let opening = letter.opening {
      parts.append("It starts: \(opening)")
    }
    parts.append(moneyAndDeadline(letter))
    if let scam = scamHint(letter) { parts.append(scam) }
    parts.append("Say read it all to hear every word.")
    return parts.filter { !$0.trimmed.isEmpty }.joined(separator: " ")
  }

  private static func moneyAndDeadline(_ letter: Letter) -> String {
    switch letter.amount {
    case .sure(let money, let minimum, let isTotal):
      let label = isTotal ? "Total" : "Amount due"
      let due = letter.due.flatMap { $0.kind == .pay || $0.kind == .other ? $0 : nil }
      var out = "\(label): \(money.spoken())"
      if let due { out += due.sure ? ", by \(due.spoken)" : ". The due date isn't clear" }
      out += "."
      if let minimum { out += " Minimum payment: \(minimum.spoken())." }
      if let other = letter.due, other.kind == .appointment || other.kind == .reply { out += " " + deadline(other) }
      return out
    case .unsure: return unsureAmount
    case .conflict: return conflictingAmounts
    case .none: return letter.due.map(deadline) ?? ""
    }
  }

  private static func deadline(_ due: DueDate) -> String {
    guard due.sure else { return "There's a date in it I can't read for sure." }
    switch due.kind {
    case .pay: return "Pay by \(due.spoken)."
    case .reply: return "Reply by \(due.spoken)."
    case .appointment: return "Appointment: \(due.spoken)."
    case .other: return "Deadline: \(due.spoken)."
    }
  }

  static func envelope(_ letter: Letter) -> String {
    var out = "This is the outside of an envelope"
    let to = [letter.recipient, letter.recipientAddress].compactMap { $0 }.joined(separator: ", ")
    if !to.isEmpty { out += ", addressed to \(to)" }
    if let sender = letter.sender { out += ", from \(sender)" }
    out += "."
    if letter.sender == nil { out += " I can't see who it's from." }
    out += " Open it and hold up the letter, then say read."
    return out
  }

  static func from(_ letter: Letter) -> String {
    letter.sender.map { "It's from \($0)." } ?? "I can't see who it's from. Try holding the top of the letter in view and say read."
  }

  static func forWhom(_ letter: Letter) -> String {
    let to = [letter.recipient, letter.recipientAddress].compactMap { $0 }.joined(separator: ", ")
    if !to.isEmpty { return "It's addressed to \(to)." }
    if let salutation = letter.salutation { return "It says Dear \(salutation)." }
    return "I can't see who it's for."
  }

  static func howMuch(_ letter: Letter) -> String {
    switch letter.amount {
    case .sure(let money, let minimum, let isTotal):
      var out = isTotal ? "The total is \(money.spoken())." : "The amount due is \(money.spoken())."
      if let minimum { out += " The minimum payment is \(minimum.spoken())." }
      if let due = letter.due, due.sure, due.kind == .pay || due.kind == .other { out += " Pay by \(due.spoken)." }
      return out
    case .unsure:
      return "I can't read the amount for sure. Hold the letter a little closer and keep it still, then say how much again."
    case .conflict:
      return conflictingAmounts
    case .none:
      if letter.amountsMentioned > 0 {
        return "I can't see an amount to pay. The letter mentions \(count(letter.amountsMentioned, "amount")); say read it all to hear them."
      }
      return "I can't see an amount to pay in this letter."
    }
  }

  static func whenDue(_ letter: Letter) -> String {
    guard let due = letter.due else { return "I can't see a due date or deadline." }
    return deadline(due)
  }

  static func isJunk(_ letter: Letter) -> String {
    if letter.isEnvelope { return "I can only see the envelope. Open it and say read." }
    switch letter.kind {
    case .advert: return "It looks like an advert, so probably junk mail."
    case .unknown: return "I'm not sure. It doesn't look like a bill or an official letter. Say read it all to hear it."
    default: return "It doesn't look like junk. It's \(kindPhrase(letter))."
    }
  }

  static func kind(_ letter: Letter) -> String {
    if letter.isEnvelope { return envelope(letter) }
    return "It's \(kindPhrase(letter))" + (letter.sender.map { " from \($0)" } ?? "") + "."
  }

  static func date(_ letter: Letter) -> String {
    letter.date.map { "It's dated \($0.spoken())." } ?? "I can't see a date on it."
  }

  static func references(_ letter: Letter) -> String {
    guard !letter.references.isEmpty else { return "I can't see an account or reference number." }
    return letter.references.prefix(3).map { $0.spoken.capitalisedFirst + "." }.joined(separator: " ")
  }

  /// The hint in the summary, or nil when there are no signs worth mentioning.
  static func scamHint(_ letter: Letter) -> String? {
    guard let first = letter.scamSigns.first else { return nil }
    return "It has signs of a scam: it \(first.spoken). \(scamAdvice)"
  }

  /// "is it a scam": the signs found, or that none were found. Never "it's genuine".
  static func scam(_ letter: Letter) -> String {
    if letter.isEnvelope { return "I can only see the envelope. Open it and say read, then ask again." }
    guard !letter.scamSigns.isEmpty else {
      return noScamSigns
    }
    let signs = letter.scamSigns.map(\.spoken)
    let list = signs.count == 1 ? signs[0] : signs.dropLast().joined(separator: ", ") + ", and " + signs[signs.count - 1]
    return "It has signs of a scam: it \(list). \(scamAdvice)"
  }

  /// One paragraph made safe to read aloud: reference numbers and digit runs spelled out, and
  /// every amount that couldn't be read for sure replaced by `notSureFigure`.
  static func forReading(_ paragraph: String, unsureMoney: Set<String>) -> String {
    let masked = masked(paragraph, unsureMoney: unsureMoney)
    // Account and reference numbers, digit by digit ("8842 1937 55" isn't "eight thousand...").
    let spelled = LetterReader.reference.replace(in: masked) { match in
      let whole = match.value(in: masked)
      guard let value = match.group(2, in: masked), value.filter(\.isASCIIDigit).count >= 3 else { return whole }
      let offset = match.range(at: 2).location - match.range.location
      return whole.utf16Substring(0, offset) + LetterText.spellOut(value)
    }
    return LetterText.forSpeech(spelled)
  }

  /// `paragraph` with every amount that couldn't be read for sure replaced by `notSureFigure`
  /// and nothing else changed. For everything that isn't speech but still reaches the user: the
  /// screen, and so VoiceOver.
  static func masked(_ paragraph: String, unsureMoney: Set<String>) -> String {
    let ns = NSMutableString(string: paragraph)
    for token in LetterText.money(paragraph).reversed() where token.money == nil || unsureMoney.contains(token.raw) {
      ns.replaceCharacters(in: token.range, with: notSureFigure)
    }
    return ns as String
  }

  private static func count(_ n: Int, _ word: String) -> String { n == 1 ? "one \(word)" : "\(n) \(word)s" }
}
