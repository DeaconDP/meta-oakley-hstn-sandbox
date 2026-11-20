/*
 * MailGrammar - what the user says inside the mail reader
 *
 * Port of the Android MailGrammar.kt. Commands: "what is this letter" / "read" (look and
 * summarise), "read it all", "who's it from", "who's it for", "how much", "when is it due", "is it
 * junk", "is it a scam" (new on iOS), "what kind of letter", "what's the date", "what's the
 * reference", "read the envelope", "next page", "new letter", "back", "skip", "start again",
 * "repeat", "carry on", "summary".
 *
 * Matching works like VoiceCommandParser: the transcript is normalised the same way (lower case,
 * punctuation gone, apostrophes closed up, so "what's" is "whats"), then a rule must match the
 * whole phrase, peeling filler words off the ends one at a time ("please read it all for me").
 * So "I'll read this later" nearby doesn't start anything. Rules are ordered, longer phrases
 * before the short words inside them. Nothing here may take another tool's opening phrase ("read
 * the label", "watch for 42") or a global command it doesn't mean to replace ("stop", "close").
 * Pure Swift.
 */

import Foundation

enum MailCommand: String, CaseIterable, Sendable {
  /// Look at what's held up and give the short summary.
  case summarise
  /// Say the summary of the current letter again (no new picture).
  case summary
  case readAll
  case startAgain
  case from
  case forWhom
  case howMuch
  case whenDue
  case isJunk
  case scam
  case kind
  case date
  case reference
  /// Look and describe as an envelope.
  case envelope
  /// Another page of the same letter.
  case nextPage
  /// Forget this letter and look at a new one.
  case newLetter
  case back
  case skip
  /// Say the sentence being read again, or the last answer.
  case repeatLast
  /// Carry on reading after a pause.
  case resume
}

enum MailGrammar {
  private static let it = "(?:it|this|that|this letter|the letter|this one|that one)"

  private static let rules: [(MailRegex, MailCommand)] = ruleSource.map { (MailRegex($0.0), $0.1) }

  private static let ruleSource: [(String, MailCommand)] = [
    (
      "(?:read|say|tell me) (?:it all|all of it|the whole (?:letter|thing|lot)|everything|every word|the full letter|the lot|the rest)|"
        + "read (?:it )?(?:out )?in full|read (?:it|the letter) out|read all",
      .readAll
    ),
    ("(?:start|read it|read) (?:again|from the (?:top|start|beginning))|from the (?:top|start|beginning)|start over", .startAgain),
    // Bare "carry on" and "continue" stay with the global grammar (VoiceCommand.continueOn).
    ("(?:carry on|keep|continue|go on) reading|resume(?: reading)?|keep going", .resume),
    ("repeat(?: (?:that|it|the sentence|the last sentence))?|say (?:it|the sentence) again", .repeatLast),
    ("(?:read|look at|check|whats on|what is on) (?:the|this) envelope|is (?:this|it) (?:an|the) envelope", .envelope),
    (
      "(?:next|another|add a|add another|turn the|the next|theres another|there is another|one more) page|page (?:two|three|four|2|3|4)|"
        + "i(?:ve| have) turned (?:it )?over|turn(?:ed)? over",
      .nextPage
    ),
    ("(?:new|another|next|a different) letter|(?:heres|here is|try) (?:another|the next) one|next one", .newLetter),
    (
      "who(?:s| is| was) \(it) from|who (?:sent|wrote) \(it)|who(?:s| is) the sender|who(?:s| is) it from|from whom?",
      .from
    ),
    (
      "who(?:s| is| was) \(it) (?:for|to|addressed to)|who(?:s| is) it addressed to|is (?:it|this) (?:for|addressed to) me|"
        + "who(?:s| is) the (?:recipient|addressee)",
      .forWhom
    ),
    (
      "how much(?: (?:is it|is that|do i owe|do i (?:have|need) to pay|is due|money|is the bill|are they asking for|should i pay))?|"
        + "what(?:s| is) the (?:amount|total|balance|bill)(?: due)?|what do i (?:owe|have to pay)|(?:the )?amount(?: due)?",
      .howMuch
    ),
    (
      "when(?:s| is) (?:it|this|that|the bill|the payment) due|when (?:do|should|must) i (?:have to |need to )?(?:pay|reply|respond)(?: by)?|"
        + "what(?:s| is) the (?:due date|deadline)|(?:the )?(?:due date|deadline)|when(?:s| is) the (?:deadline|appointment)|pay by when",
      .whenDue
    ),
    (
      "is (?:it|this|that)(?: letter)? (?:a scam|a con|genuine|real|legit|legitimate|safe|a fake|fake)|"
        + "(?:does it|does this) look like a scam|(?:any )?scam signs|could (?:it|this) be a scam|scam check|check for scams?",
      .scam
    ),
    ("is (?:it|this|that) (?:junk|junk mail|spam|an advert|advertising|a flyer|important)|(?:is it|is this) junk", .isJunk),
    (
      "what (?:kind|type|sort) of (?:letter|thing|mail) is (?:it|this|that)|what (?:kind|type|sort) (?:is it|of letter)|is (?:it|this) a bill",
      .kind
    ),
    (
      "what(?:s| is) the date(?: on (?:it|this|the letter))?|when was (?:it|this) (?:sent|written|dated)|what date is (?:it|this) (?:from|dated)",
      .date
    ),
    (
      "what(?:s| is) (?:the|my) (?:account|reference|customer|policy|nhs|invoice) number|(?:read|say) the (?:account|reference) number|"
        + "what(?:s| is) the reference|reference number|account number",
      .reference
    ),
    ("(?:give me |say )?(?:the |a )?summary(?: again)?|summari[sz]e(?: it)?|sum (?:it )?up|tell me again|what was it again", .summary),
    ("(?:go )?back(?: a (?:sentence|bit|line))?|previous(?: sentence)?|last sentence|say the last (?:sentence|bit|line)", .back),
    ("skip(?: (?:this|that|ahead|it|forward|a sentence))?|next(?: sentence)?|forward", .skip),
    (
      "read|read (?:it|this|the letter|this letter|it to me|my letter)|look(?: at it)? again|try again|scan (?:it|this letter)|"
        + "what(?:s| is) (?:this|that|it)(?: about)?|what(?:s| is) (?:this|that|the) (?:letter|envelope)(?: about)?|"
        + "what does (?:it|this|the letter) say|what(?:s| is) in (?:this|the) letter|who(?:s| is) (?:this|the) letter from|"
        + "is this (?:letter )?(?:a bill|junk mail|for me)",
      .summarise
    ),
  ]

  private static let leadingFiller: [[String]] = [
    ["can", "you"], ["could", "you"], ["would", "you"], ["will", "you"], ["i", "want", "to"], ["i", "would", "like", "to"],
    ["id", "like", "to"], ["i", "want", "you", "to"], ["please"], ["just"], ["now"], ["um"], ["uh"], ["er"], ["hey"], ["ok"],
    ["okay"], ["so"], ["lets"], ["and"], ["reader"],
  ]
  private static let trailingFiller: [[String]] = [["thank", "you"], ["for", "me"], ["please"], ["now"], ["thanks"]]

  /// The transcript normalised, then again after each piece of filler peeled off: what a rule may
  /// match, longest first. LetterGrammar matches the same way.
  static func phrases(_ transcript: String) -> [String] {
    var tokens = VoiceCommandParser.normalize(transcript)
    var out: [String] = []
    while !tokens.isEmpty {
      out.append(tokens.joined(separator: " "))
      guard let shorter = stripOneFiller(tokens) else { break }
      tokens = shorter
    }
    return out
  }

  /// A command inside the tool, or nil.
  static func parse(_ transcript: String) -> MailCommand? {
    var tokens = VoiceCommandParser.normalize(transcript)
    while !tokens.isEmpty {
      let phrase = tokens.joined(separator: " ")
      if let command = rules.first(where: { $0.0.matchesWhole(phrase) })?.1 { return command }
      guard let shorter = stripOneFiller(tokens) else { return nil }
      tokens = shorter
    }
    return nil
  }

  private static func stripOneFiller(_ tokens: [String]) -> [String]? {
    for filler in leadingFiller where tokens.count > filler.count && Array(tokens.prefix(filler.count)) == filler {
      return Array(tokens.dropFirst(filler.count))
    }
    for filler in trailingFiller where tokens.count > filler.count && Array(tokens.suffix(filler.count)) == filler {
      return Array(tokens.dropLast(filler.count))
    }
    return nil
  }
}
