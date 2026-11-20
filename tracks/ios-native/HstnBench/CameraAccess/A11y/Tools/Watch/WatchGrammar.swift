/*
 * WatchGrammar - what the user says to open and inside "Watch for text"
 *
 * Ported from Android's tools/watch/WatchGrammar.kt, same phrases. Whole-phrase rules after filler
 * is stripped (HeardText.normalize), so nearby talk that only contains "watch" doesn't count.
 *
 * `opens`: phrases that open this tool from anywhere and carry the free target ("watch for 42",
 * "tell me when you see exit", "look out for platform 9", "find Boots", "watch for text"). The
 * integrator calls it from the global voice routing.
 * `parse`: commands inside the tool: stop watching, carry on watching, what are you watching for,
 * where is it, watch for something else (with or without a new target), a fresh "watch for X",
 * and the alive tick (off, on, every N seconds). It leaves "stop", "close", "help" and other tools'
 * openers to the app's own grammar. Pure, unit-tested.
 */

import Foundation

enum WatchCommand: Equatable, Sendable {
  /// Stop watching; the target is kept so "carry on watching" restarts it.
  case stop
  case resume
  /// "What are you watching for?"
  case whatTarget
  /// "Where is it?"
  case whereIsIt
  /// Watch for something else: the target as said, or nil to ask for it.
  case newTarget(String?)
  /// The alive tick: seconds between ticks, 0 = off, nil = back on at the default.
  case ticks(Int?)
}

/// "watch for 42" from anywhere: open Watch for text, with the target if one was said.
struct WatchOpenRequest: Equatable, Sendable {
  var target: String?
}

enum WatchGrammar {
  private static let lead =
    "(?:(?:start |keep )?watch(?:ing)? (?:out )?for|look(?:ing)? out for|keep an eye out for|"
    + "(?:tell|let) me (?:know )?(?:when|if) you see|find(?: me)?(?! out(?: |$))|look for)"

  private static let openWithTarget = HeardText.Pattern("^\(lead) .+$")
  private static let leadInLight = HeardText.Pattern("(?:^| )\(lead)(?= )")
  private static let openTool = HeardText.Pattern(
    "^(?:(?:open|start|switch to)(?: the)? )?watch(?:ing)? for text(?: tool)?$|^text watcher$")

  /// Words that mean "the tool itself", not a target.
  private static let noTarget: Set<String> = ["text", "something", "words", "a word", "a number"]

  /// From a raw transcript: does it open Watch for text, and with what target?
  static func opens(_ transcript: String) -> WatchOpenRequest? {
    opens(normalized: HeardText.normalize(transcript), light: HeardText.light(transcript))
  }

  static func opens(normalized: String, light: String) -> WatchOpenRequest? {
    if openTool.matches(normalized) { return WatchOpenRequest(target: nil) }
    guard openWithTarget.matches(normalized) else { return nil }
    var target = HeardText.after(leadInLight, in: light)
    if let found = target, found.hasPrefix("the ") { target = String(found.dropFirst(4)) }
    target = target?.trimmingCharacters(in: .whitespaces)
    if let found = target, noTarget.contains(found) || found.isEmpty { target = nil }
    return WatchOpenRequest(target: target)
  }

  // MARK: Commands inside the tool. Specific phrases first.

  private static let stop = HeardText.Pattern(
    "^(?:(?:stop|cancel|quit|end|finish|pause) (?:watching|looking|searching)(?: for (?:it|that|this|now|.{1,30}))?|"
      + "don'?t (?:watch|look) (?:for (?:it|that) )?any ?more|never mind|forget (?:it|that)|cancel)$")

  private static let resume = HeardText.Pattern(
    "^(?:(?:start|keep|carry on|continue|resume|go on|go back to) (?:watching|looking)(?: for it)?(?: again)?|"
      + "watch again|start again|keep going)$")

  private static let whatTarget = HeardText.Pattern(
    "^(?:what (?:are|am|were) (?:you|i|we) (?:watching|looking|waiting|searching) (?:out )?for|"
      + "what'?s the target|what (?:are|were) you (?:told|asked) to (?:watch|look) for|"
      + "what (?:did|do) i (?:ask|tell) you to (?:watch|look) for|what (?:are|was) it)$")

  private static let whereIs = HeardText.Pattern(
    "^(?!where (?:am|are (?:we|you)|did (?!you)))(?:where(?:'s| is| was| are)?(?: [\\w']+){0,3}|"
      + "which (?:side|way)(?: is it| was it)?|where did you (?:last )?see it)$")

  private static let somethingElseWords =
    "(?:(?:watch|look) (?:out )?for something else|something else|change (?:it |the target )?to|instead watch for|now watch for)"
  private static let somethingElseLead = HeardText.Pattern("(?:^| )\(somethingElseWords)(?= |$)")
  private static let somethingElse = HeardText.Pattern("^\(somethingElseWords)(?: .+)?$")

  private static let ticksOff = HeardText.Pattern(
    "^(?:(?:turn |switch )?(?:the )?(?:ticks?|ticking|clicks?|clicking)(?: sound)? off|"
      + "(?:turn off|switch off|stop|no|mute|no more)(?: the)? (?:ticks?|ticking|clicks?|clicking)|stop ticking)$")

  private static let ticksOn = HeardText.Pattern(
    "^(?:(?:turn |switch )?(?:the )?(?:ticks?|ticking|clicks?) (?:back )?on|(?:turn|switch) (?:the )?(?:ticks?|ticking|clicks?) (?:back )?on|"
      + "(?:turn|switch) on (?:the )?(?:ticks?|ticking|clicks?)|start ticking)$")

  private static let ticksEvery = HeardText.Pattern("^(?:tick(?:s|ing)?|click(?:s|ing)?) (?:once )?every ([a-z0-9 ]+?) seconds?$")

  /// A command inside the tool, from a raw transcript.
  static func parse(_ transcript: String) -> WatchCommand? {
    parse(normalized: HeardText.normalize(transcript), light: HeardText.light(transcript))
  }

  static func parse(normalized: String, light: String) -> WatchCommand? {
    guard !normalized.isEmpty else { return nil }
    if ticksOff.matches(normalized) { return .ticks(0) }
    if ticksOn.matches(normalized) { return .ticks(nil) }
    if let groups = ticksEvery.wholeMatchGroups(normalized), let spoken = groups[1] {
      let words = spoken.split(separator: " ").map(String.init)
      if let seconds = WatchNumberWords.parse(words).flatMap(Int.init), seconds > 0 { return .ticks(seconds) }
    }
    if somethingElse.matches(normalized) {
      var after = HeardText.after(somethingElseLead, in: light)
      if let found = after, found.hasPrefix("then ") { after = String(found.dropFirst(5)) }
      after = after?.trimmingCharacters(in: .whitespaces)
      if let found = after, found.isEmpty || noTarget.contains(found) { after = nil }
      return .newTarget(after)
    }
    if stop.matches(normalized) { return .stop }
    if resume.matches(normalized) { return .resume }
    if whatTarget.matches(normalized) { return .whatTarget }
    if whereIs.matches(normalized) { return .whereIsIt }
    // "watch for 73" while watching: a new target, with the same phrases that open the tool.
    if let request = opens(normalized: normalized, light: light) { return .newTarget(request.target) }
    return nil
  }
}
