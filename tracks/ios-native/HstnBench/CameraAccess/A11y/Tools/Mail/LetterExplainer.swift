/*
 * LetterExplainer - "explain this letter" on the phone, from fixed rules
 *
 * A plain-English explanation built from what the mail reader already found (LetterRecord): the
 * kind of letter, who it's from, what it's about, the amount (only a sure figure: the money rule),
 * the date to act by, and the scam hint. Common letter kinds get a sentence on what such letters
 * are and what people usually do: a bill, a final notice, an appointment, a bank letter, council
 * tax, a benefit letter, a fine and an advert. When the letter doesn't say something that kind of
 * letter normally says (no amount on a bill, no date on a final notice), the explanation says so.
 * No cloud call; LetterExplainOnline is the optional AI version, only when asked. Pure Swift.
 */

import Foundation

enum LetterTopic: String, CaseIterable, Sendable {
  case finalNotice, councilTax, benefit, fine, appointment, bill, bank, advert, medical, official, personal, unknown

  /// Topics that normally ask for money: a missing amount or date is worth saying.
  var asksForMoney: Bool { [.finalNotice, .councilTax, .fine, .bill].contains(self) }
}

enum LetterExplainer {
  private static let finalNotice = MailRegex(
    "\\b(?:final (?:notice|demand|reminder|warning)|overdue|in arrears|arrears|debt collect(?:or|ion|ors)|reminder notice)\\b",
    ignoreCase: true)
  private static let councilTax = MailRegex("\\bcouncil tax\\b", ignoreCase: true)
  private static let benefit = MailRegex(
    "\\b(?:universal credit|pension credit|housing benefit|child benefit|attendance allowance|carer'?s allowance|"
      + "personal independence payment|PIP|ESA|JSA|jobseeker'?s allowance|state pension|DWP|department for work and pensions)\\b",
    ignoreCase: true)
  private static let anyBenefit = MailRegex("\\bbenefits?\\b", ignoreCase: true)
  private static let fine = MailRegex(
    "\\b(?:penalty charge notice|PCN|fixed penalty|parking (?:fine|charge notice|charge)|penalty notice|speeding|"
      + "notice of intended prosecution|congestion charge|unpaid fare|(?:a|the) fine of)\\b",
    ignoreCase: true)

  static func topic(_ record: LetterRecord) -> LetterTopic {
    let text = record.text + "\n" + (record.subject ?? "")
    let kind = record.letterKind
    if kind == .advert { return .advert }
    if fine.contains(text) { return .fine }
    if councilTax.contains(text) { return finalNotice.contains(text) ? .finalNotice : .councilTax }
    if finalNotice.contains(text) && (record.amount != .none || kind == .bill || kind == .bank) { return .finalNotice }
    if kind != .bill && (benefit.contains(text) || (kind == .official && anyBenefit.contains(text))) { return .benefit }
    if record.deadlineKind == .appointment { return .appointment }
    switch kind {
    case .bill: return .bill
    case .bank: return .bank
    case .medical: return .medical
    case .official: return .official
    case .personal: return .personal
    case .advert: return .advert
    case .unknown: return .unknown
    }
  }

  static func intro(_ topic: LetterTopic) -> String {
    switch topic {
    case .finalNotice:
      "This is a final notice. It says a payment is overdue. Letters like this usually come before extra charges or debt collection."
    case .councilTax:
      "This is about council tax, the local tax on your home that pays for council services."
    case .benefit:
      "This is about a benefit, such as Universal Credit or a pension. Letters like this often tell you about a payment, a change, or something you need to send."
    case .fine:
      "This is a penalty or fine, for example for parking. Paying early is often cheaper, and there's usually a way to challenge it."
    case .appointment:
      "This is about an appointment."
    case .bill:
      "This is a bill. It asks you to pay for something you've used or bought."
    case .bank:
      "This is from a bank or building society. Letters like this often tell you about changes to an account or card."
    case .advert:
      "This looks like an advert. You don't have to do anything with it."
    case .medical:
      "This is a medical or health letter."
    case .official:
      "This is an official letter, for example from a council or a government department."
    case .personal:
      "This looks like a personal letter."
    case .unknown:
      "I'm not sure what kind of letter this is."
    }
  }

  static func nextStep(_ topic: LetterTopic) -> String? {
    switch topic {
    case .finalNotice:
      "If you can't pay, contact the sender soon. They can often agree a payment plan, and free debt advice is available, for example from Citizens Advice."
    case .councilTax:
      "If you live alone or are struggling to pay, you may be able to get a discount or a reduction. Your council can tell you."
    case .benefit:
      "If it asks for information, reply by the date so your payments aren't affected."
    case .fine:
      "If you think it's wrong, the letter should say how to challenge it and by when."
    case .appointment:
      "If you can't go, contact them to change it."
    case .bill:
      "If it looks right, pay it by the date. If something looks wrong, contact the sender using the details on the letter."
    case .bank:
      "If it asks you to do something, check by calling the number on the back of your card, not one in the letter."
    case .advert:
      "You can recycle it."
    case .medical, .official, .personal, .unknown:
      nil
    }
  }

  /// The explanation, spoken. `offerOnline` adds how to ask for the AI one (only when a key is set).
  static func explain(_ record: LetterRecord, offerOnline: Bool) -> String {
    let topic = topic(record)
    var parts = [intro(topic)]

    if let sender = record.sender {
      parts.append("It's from \(sender).")
    } else if topic != .advert {
      parts.append("The letter doesn't say clearly who it's from.")
    }
    if let subject = record.subject, topic != .advert { parts.append("It's about: \(subject.trimmingTrailing(["."])).") }

    switch record.amount {
    case .sure(let currency, let minor, let isTotal, let minimum):
      let money = Money(currency: currency, minor: minor).spoken()
      var line = isTotal ? "The total is \(money)." : "It asks you to pay \(money)."
      if let minimum { line += " The smallest payment you can make is \(Money(currency: currency, minor: minimum).spoken())." }
      parts.append(line)
    case .notSure:
      parts.append("There's an amount in it, but I couldn't read it for sure, so I won't guess it. Hold the letter closer and ask how much.")
    case .none:
      if topic.asksForMoney { parts.append("I couldn't find an amount to pay in it.") }
    }

    if let spoken = record.dueSpoken {
      if !record.dueSure {
        parts.append("There's a date in it I couldn't read for sure.")
      } else {
        switch record.deadlineKind {
        case .appointment: parts.append("The appointment is on \(spoken).")
        case .reply: parts.append("You need to reply by \(spoken).")
        case .pay?: parts.append("Pay by \(spoken).")
        case .other?, nil: parts.append("The date to act by is \(spoken).")
        }
      }
    } else if topic.asksForMoney || topic == .appointment {
      parts.append(topic == .appointment ? "I couldn't find the date of the appointment." : "I couldn't find a date to pay by.")
    }

    if let step = nextStep(topic) { parts.append(step) }
    if !record.signs.isEmpty {
      parts.append("It also has signs of a scam, so \(LetterSpeech.scamAdvice.lowercasedFirst)")
    }
    parts.append("That's a general explanation from rules on your phone.")
    if offerOnline { parts.append("For an AI explanation of this letter, say explain online.") }
    return parts.joined(separator: " ")
  }
}

extension String {
  fileprivate var lowercasedFirst: String { first.map { $0.lowercased() + dropFirst() } ?? self }
}
