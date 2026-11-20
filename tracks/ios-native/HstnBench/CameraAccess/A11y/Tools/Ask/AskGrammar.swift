/*
 * AskGrammar - spotting a question about text that was just read, and what kind it is
 *
 * Ported from Android's tools/ask/AskGrammar.kt, same phrases. Whole-phrase rules on
 * HeardText.normalize, so "what does recondite mean" is a question and room chatter isn't.
 * Kinds: define a word, spell it, who someone is, what something is (a name in the text, else
 * the dictionary), recap, find a passage, and open questions (only the optional online path can
 * try those).
 *
 * Follow-ups ("more", "next", "no") are things a room says all the time, so they only count for a
 * while after an answer that offers them: AskFollowUps is opened by AskAnswerer and expires after
 * two minutes. "Spell it" always counts. "Find me ..." is left to Watch for text. Pure, unit-tested.
 */

import Foundation

enum AskKind: Equatable, Sendable {
  case define
  /// Subject nil means the last word talked about.
  case spell
  case who
  /// A name in the text if it's there, else a dictionary word.
  case what
  case recap
  case find
  /// Follow-up: further senses, mentions or matches.
  case more
  /// Follow-up: "no" after "Did you mean recondite?": define the word as heard.
  case no
  /// Anything else ("why did he do that?").
  case open
}

struct AskQuestion: Equatable, Sendable {
  var kind: AskKind
  var subject: String?
  var lastTime = false
}

/// Which follow-ups count right now, and until when.
@MainActor
final class AskFollowUps {
  static let windowSeconds: TimeInterval = 120

  private var kinds: Set<AskKind> = []
  private var until = Date.distantPast
  var clock: () -> Date

  init(clock: @escaping () -> Date = { Date() }) {
    self.clock = clock
  }

  /// "more"/"next" for `seconds` (and "no" if `no`).
  func open(more: Bool, no: Bool, seconds: TimeInterval = AskFollowUps.windowSeconds) {
    kinds = []
    if more { kinds.insert(.more) }
    if no { kinds.insert(.no) }
    until = clock().addingTimeInterval(seconds)
  }

  func close() { kinds = [] }

  func allowed(_ kind: AskKind) -> Bool { kinds.contains(kind) && clock() < until }
}

enum AskGrammar {
  private struct Rule {
    var pattern: HeardText.Pattern
    var kind: AskKind
    var lastTime = false

    init(_ pattern: String, _ kind: AskKind, lastTime: Bool = false) {
      self.pattern = HeardText.Pattern("^(?:\(pattern))$")
      self.kind = kind
      self.lastTime = lastTime
    }
  }

  private static let word = "(?:the )?(?:word |name )?"
  private static let text = "(?:it|the (?:text|book|letter|page|story|chapter|author)|he|she|they|you)"

  /// "What is the X" subjects that aren't about the text.
  private static let notText = HeardText.Pattern(
    "^(?:time|date|day|weather|forecast|battery|batteries|matter|problem|point|page|speed|rate|"
      + "plan|score|news|deal|password|wifi|price|cost|colou?r(?: .*)?|light(?: .*)?|"
      + "time now|best .*|nearest .*|next .*)$")

  private static let rules: [Rule] = [
    // Follow-ups first (they're gated).
    Rule(
      "more|tell me more|more (?:meanings?|please)|(?:any )?other meanings?|what else|anything else|"
        + "next|next (?:match|mention|bit|part|sentence)|find (?:the )?next|find (?:it )?again|another|another one", .more),
    Rule(
      "(?:no|nope|no not that(?: one)?|not that one|(?:no )?the (?:other|first) one|no (?:the )?one i said|"
        + "no i meant (?:what i said|the one i said)|that'?s not (?:it|what i said))", .no),
    // Spelling.
    Rule("(?:spell|spell out|how do you spell|how is|how'?s) (?:it|that|the word|that word|this word)(?: spelt| spelled)?(?: again)?", .spell),
    Rule("(?:how do (?:you|i) spell|spell|spell out|can i have the spelling of|spelling of) \(word)(.+?)", .spell),
    Rule("how (?:is|do you write) \(word)(.+?) (?:spelt|spelled|written)", .spell),
    // Definitions.
    Rule("what does \(word)(.+?) mean(?: again)?", .define),
    Rule("what(?:'s| is| was) the (?:meaning|definition) of \(word)(.+)", .define),
    Rule("(?:define|meaning of|definition of|look up|dictionary) \(word)(.+)", .define),
    Rule("what(?:'s| is) (?:a |an )(.+?)(?: again)?", .define),
    Rule("what(?:'s| is| are) (.+?) again", .define),
    Rule("what do(?:es)? (?:you mean by|they mean by|it mean by) \(word)(.+)", .define),
    // Recap (before the open "where did ..." rule).
    Rule(
      "what happened (?:last time|the last time|before|previously|in the last (?:session|chapter|bit)|yesterday|then|last)",
      .recap, lastTime: true),
    Rule(
      "where (?:did|do) (?:we|i) (?:leave off|leave it|stop|get to|finish|break off)(?: last time)?|where were we|"
        + "what was (?:i|we) reading(?: last time)?|remind me where (?:we|i) (?:were|was|left off)", .recap, lastTime: true),
    Rule(
      "what happened(?:(?: so)? far| just now| there| earlier)?|recap|give me a recap|a recap|recap (?:please|(?:so )?far|that)|"
        + "summar(?:ise|ize)(?: (?:it|that|(?:so )?far))?|remind me what happened|what'?s been happening|what did i miss|"
        + "catch me up|what was that (?:bit|part) about", .recap),
    // Finding.
    Rule("what (?:did|does) \(text) (?:say|said|tell (?:me|us)|mention) about (.+)", .find),
    Rule("(?:did|does|has) \(text) (?:say|mention) (?:(?:anything|something) )?about (.+)|(?:did|does|has) \(text) mention (.+)", .find),
    Rule(
      "(?:find|search for|search|where does it (?:mention|say|talk about)|"
        + "read (?:me )?(?:the )?(?:bit|part|sentence) (?:about|with)|go back to (?:the )?(?:bit|part) about) (.+)", .find),
    Rule("where (?:was|were|is|are) (.+?) mentioned", .find),
    Rule("what did (?!it |you |that |i |we )(.+?) say(?: .*)?", .find),
    // Who and what.
    Rule("who(?:'s| is| was| are| were) (?!this letter|that letter|it from|there|calling|that at)(.+?)(?: again)?", .who),
    Rule("(?:remind me who|tell me who) (.+?) (?:is|was)", .who),
    Rule("what(?:'s| is| was| are| were) the (.+?)(?: again)?", .what),
    // Open questions.
    Rule("why (?:did|does|do|is|was|were|are|would|didn'?t|doesn'?t|has|had) (.+)", .open),
    Rule("where (?:did|does|was|were|is|are) (.+)", .open),
    Rule("how (?:did|does|do|is|was|were|old|many|much|long) (.+)", .open),
    Rule("what did (?!it |you |that )(.+?) (?:do|mean|want|think|see|find)(?: .*)?", .open),
    Rule("when (?:did|does|is|was|were|do) (.+)", .open),
    Rule("(?:does it|did it|does the (?:text|book|letter|page)) say (.+)", .open),
  ]

  /// The kind of question `normalized` (HeardText.normalize) is, or nil if it isn't one.
  /// `followUps` nil means follow-ups never count (a partial transcript, say).
  @MainActor
  static func classify(_ normalized: String, followUps: AskFollowUps?) -> AskQuestion? {
    var text = normalized.trimmingCharacters(in: .whitespaces)
    if text.hasSuffix("?") { text = String(text.dropLast()).trimmingCharacters(in: .whitespaces) }
    guard !text.isEmpty else { return nil }
    for rule in rules {
      guard let groups = rule.pattern.wholeMatchGroups(text) else { continue }
      if rule.kind == .more || rule.kind == .no {
        guard let followUps, followUps.allowed(rule.kind) else { return nil }
        return AskQuestion(kind: rule.kind)
      }
      if rule.kind == .find, text.hasPrefix("find me ") { return nil }  // Watch for text's phrase
      var subject = groups.dropFirst().last(where: { ($0?.trimmingCharacters(in: .whitespaces).isEmpty == false) }) ?? nil
      subject = subject.map(cleanSubject)
      if rule.kind == .what, let subject, notText.matches(subject) { return nil }
      if ![.spell, .recap, .open].contains(rule.kind), subject?.isEmpty ?? true { return nil }
      return AskQuestion(kind: rule.kind, subject: subject?.isEmpty == true ? nil : subject, lastTime: rule.lastTime)
    }
    return nil
  }

  /// From a raw transcript.
  @MainActor
  static func classify(transcript: String, followUps: AskFollowUps?) -> AskQuestion? {
    classify(HeardText.normalize(transcript), followUps: followUps)
  }

  /// True if `transcript` is already a whole question (follow-ups don't count), so a reader can
  /// stop as soon as a partial result forms one.
  @MainActor
  static func isQuestion(_ transcript: String) -> Bool {
    classify(transcript: transcript, followUps: nil) != nil
  }

  private static func cleanSubject(_ raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespaces)
    for prefix in ["the word ", "the name "] where s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
    for suffix in [" again", " please"] where s.hasSuffix(suffix) { s = String(s.dropLast(suffix.count)) }
    return s.trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
  }
}
