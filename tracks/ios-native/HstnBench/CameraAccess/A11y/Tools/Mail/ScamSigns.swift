/*
 * ScamSigns - fixed phrases that often show up in scam letters (ROADMAP U1, notes/use-cases.md)
 *
 * New on iOS. Covers the Android list (TODO.md "Mail: scam-sign rules": urgent payment, gift
 * cards, "final notice" pressure, bank details or passwords asked for) plus a mismatched sender
 * (an organisation that wants replies at a free email address or a mobile number) and odd
 * payment methods (vouchers, crypto, cash by post, a courier to collect). The rules only look at
 * the text already read, on the phone. The result is a hint, never a verdict: "it has signs of a
 * scam, check with someone you trust". Nothing here can call a letter safe; with no signs found
 * the answer is "No scam signs found", plus that this doesn't prove anything.
 *
 * Real letters use some of these words too (a council's "final notice"), so a single weak sign is
 * not enough: a hint needs a strong sign (payment by gift card or crypto, asking for a PIN,
 * password or bank details, a fee to release a prize, a mismatched sender) or two different weak
 * ones. Pure Swift.
 */

import Foundation

enum ScamSign: String, CaseIterable, Sendable {
  /// Gift cards, vouchers, crypto, money transfer services, cash by post, a courier to collect.
  case oddPayment
  /// Asks for a PIN, password, one-time code or full card details.
  case asksForSecrets
  /// A prize, lottery or inheritance, often with a fee to release it.
  case prizeOrFee
  /// Pressure: "final notice", "within 24 hours", "account will be suspended".
  case urgency
  /// Threats: arrest, police, a warrant.
  case threat
  /// "Don't tell anyone", "keep this secret".
  case secrecy
  /// An organisation (a bank, a council, HMRC...) that wants replies at a free email address or a
  /// mobile number.
  case mismatchedSender

  var isStrong: Bool { self == .oddPayment || self == .asksForSecrets || self == .prizeOrFee || self == .mismatchedSender }

  /// Finishes "It asks ..." / "It mentions ..." in plain words.
  var spoken: String {
    switch self {
    case .oddPayment: "asks for payment in an unusual way, like gift cards, vouchers, crypto, cash or a money transfer service"
    case .asksForSecrets: "asks for a PIN, password, code, or your bank or card details"
    case .prizeOrFee: "talks about a prize or windfall, or a fee to release money"
    case .urgency: "pushes you to act very quickly"
    case .threat: "threatens arrest or police action"
    case .secrecy: "asks you to keep it secret"
    case .mismatchedSender: "says it's from an organisation, but gives a personal email address or mobile number to reply to"
    }
  }
}

enum ScamSigns {
  private static let patterns: [(ScamSign, MailRegex)] = [
    (
      .oddPayment,
      MailRegex(
        "\\b(?:gift ?cards?|itunes (?:cards?|vouchers?)|google play (?:cards?|vouchers?)|steam (?:cards?|vouchers?)|"
          + "amazon (?:gift )?vouchers?|apple (?:gift )?cards?|paysafe ?cards?|pcs vouchers?|neosurf|prepaid (?:debit )?cards?|"
          + "bitcoin|crypto ?currency|crypto|western union|moneygram|wire transfer|money order|"
          + "(?:send|post) (?:the )?cash|cash (?:by|in the) post|courier (?:will )?(?:collect|call)|pay (?:in|with) vouchers?)\\b",
        ignoreCase: true)
    ),
    (
      .asksForSecrets,
      MailRegex(
        "\\b(?:(?:your|the) (?:pin|password|passcode|one[- ]time (?:code|passcode)|security code|cvv|card number)|"
          + "confirm your (?:bank|card|account|banking|security|login) details|verify your (?:account|identity|bank|card) details|"
          + "(?:send|give|provide|tell|enter|update) (?:us )?(?:with )?your (?:full )?(?:bank|banking|card|account|login|online banking) "
          + "(?:details|number|password)|online banking (?:password|login|log in|details))\\b",
        ignoreCase: true)
    ),
    (
      .prizeOrFee,
      MailRegex(
        "\\b(?:you have won|you've won|you are a winner|claim your (?:prize|winnings|reward)|lottery|sweepstake|"
          + "inheritance|unclaimed (?:funds|money)|(?:processing|release|admin(?:istration)?|handling|clearance) fee)\\b",
        ignoreCase: true)
    ),
    (
      .urgency,
      MailRegex(
        "\\b(?:final (?:notice|warning|demand)|immediate action|act (?:now|immediately)|urgent(?:ly)? (?:action|response|payment)|"
          + "within (?:24|48|twenty[- ]four|forty[- ]eight) hours|(?:will be|has been) (?:suspended|frozen|closed|blocked)|"
          + "pay (?:now|today|immediately) to avoid|last chance to pay)\\b",
        ignoreCase: true)
    ),
    (
      .threat,
      MailRegex("\\b(?:arrest(?:ed)?|warrant|police (?:action|will)|criminal (?:charges|proceedings|record))\\b", ignoreCase: true)
    ),
    (
      .secrecy,
      MailRegex(
        "\\b(?:do not|don't) (?:tell|discuss this with) (?:anyone|anybody|your (?:family|bank))|keep this (?:a )?secret\\b",
        ignoreCase: true)
    ),
  ]

  private static let freeEmail = MailRegex(
    "\\b[A-Z0-9._%+-]+@(?:gmail|googlemail|hotmail|outlook|live|yahoo|ymail|aol|icloud|me|mail|gmx|proton|protonmail|yandex)"
      + "\\.(?:com|co\\.uk|net|me|ru)\\b",
    ignoreCase: true)
  private static let mobileNumber = MailRegex("(?:\\+44 ?7|\\b07)\\d{3} ?\\d{3} ?\\d{3}\\b")
  private static let organisation = MailRegex(
    "\\b(?:bank|building society|council|hmrc|dvla|dwp|nhs|tv licensing|royal mail|post office|police|court|"
      + "department for|ministry|government|gov\\.uk|amazon|paypal|apple|microsoft)\\b",
    ignoreCase: true)
  private static let getInTouch = MailRegex(
    "\\b(?:reply|respond|write|email|e-mail|contact|text|call|whatsapp|send)\\b", ignoreCase: true)

  /// A bank, council, government body, NHS or big company (by the letter's kind or the sender's
  /// name) that wants replies at a free email address, or at a mobile number on a line that asks
  /// you to get in touch. Bills aren't counted on kind alone: a small trader may well use Gmail.
  static func isMismatchedSender(_ text: String, sender: String?, kind: LetterKind) -> Bool {
    let claimsOrganisation =
      [LetterKind.bank, .official, .medical].contains(kind) || sender.map { organisation.contains($0) } == true
    guard claimsOrganisation else { return false }
    if freeEmail.contains(text) { return true }
    return text.split(separator: "\n").contains { line in
      mobileNumber.contains(String(line)) && getInTouch.contains(String(line))
    }
  }

  /// The signs worth mentioning, strongest first; empty when there aren't enough to say anything.
  /// `sender` and `kind` (as the reader found them) let a mismatched sender count.
  static func find(_ text: String, sender: String? = nil, kind: LetterKind = .unknown) -> [ScamSign] {
    var found = patterns.filter { $0.1.contains(text) }.map(\.0)
    if isMismatchedSender(text, sender: sender, kind: kind) { found.append(.mismatchedSender) }
    let strong = found.contains(where: \.isStrong)
    guard strong || found.count >= 2 else { return [] }
    return found.filter(\.isStrong) + found.filter { !$0.isStrong }
  }
}
