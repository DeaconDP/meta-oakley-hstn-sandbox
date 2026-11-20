/*
 * ScamSigns - fixed phrases that often show up in scam letters (ROADMAP U1, notes/use-cases.md)
 *
 * New on iOS; the Android mail reader doesn't have it yet (TODO.md "Mail: scam-sign rules"). The
 * rules only look at the text already read, on the phone. The result is a hint, never a verdict:
 * "it has signs of a scam, check with someone you trust". Nothing here can say a letter is
 * genuine; with no signs found the answer is "I found no scam signs", plus that it can't tell.
 *
 * Real letters use some of these words too (a council's "final notice"), so a single weak sign is
 * not enough: a hint needs a strong sign (payment by gift card or crypto, asking for a PIN or
 * password, a fee to release a prize) or two different weak ones. Pure Swift.
 */

import Foundation

enum ScamSign: String, CaseIterable, Sendable {
  /// Gift cards, vouchers, crypto, money transfer services.
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

  var isStrong: Bool { self == .oddPayment || self == .asksForSecrets || self == .prizeOrFee }

  /// Finishes "It asks ..." / "It mentions ..." in plain words.
  var spoken: String {
    switch self {
    case .oddPayment: "asks for payment by gift card, crypto or a money transfer service"
    case .asksForSecrets: "asks for a PIN, password, code or card details"
    case .prizeOrFee: "talks about a prize or windfall, or a fee to release money"
    case .urgency: "pushes you to act very quickly"
    case .threat: "threatens arrest or police action"
    case .secrecy: "asks you to keep it secret"
    }
  }
}

enum ScamSigns {
  private static let patterns: [(ScamSign, MailRegex)] = [
    (
      .oddPayment,
      MailRegex(
        "\\b(?:gift ?cards?|itunes (?:cards?|vouchers?)|google play (?:cards?|vouchers?)|steam (?:cards?|vouchers?)|"
          + "amazon (?:gift )?vouchers?|bitcoin|crypto ?currency|crypto|western union|moneygram|wire transfer)\\b",
        ignoreCase: true)
    ),
    (
      .asksForSecrets,
      MailRegex(
        "\\b(?:(?:your|the) (?:pin|password|passcode|one[- ]time (?:code|passcode)|security code|cvv|card number)|"
          + "confirm your (?:bank|card|account|banking|security) details|verify your (?:account|identity|bank|card) details)\\b",
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
          + "within (?:24|48|twenty[- ]four|forty[- ]eight) hours|(?:will be|has been) (?:suspended|frozen|closed|blocked))\\b",
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

  /// The signs worth mentioning, strongest first; empty when there aren't enough to say anything.
  static func find(_ text: String) -> [ScamSign] {
    let found = patterns.filter { $0.1.contains(text) }.map(\.0)
    let strong = found.contains(where: \.isStrong)
    guard strong || found.count >= 2 else { return [] }
    return found.filter(\.isStrong) + found.filter { !$0.isStrong }
  }
}
