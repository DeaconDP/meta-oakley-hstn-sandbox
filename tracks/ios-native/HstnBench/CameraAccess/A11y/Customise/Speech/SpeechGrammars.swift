/*
 * SpeechGrammars - voice phrases for the speech, tips and descriptions areas
 *
 * Whole phrases only, after polite filler is peeled off (SettingsWords.phrase), so nearby talk
 * doesn't change settings. None of them claims a VoiceCommand phrase: "faster", "slower",
 * "short answers", "normal answers" and "detailed answers" stay with VoiceControl, which sends
 * them through SpeechChanges so they are recorded too. The one exception is while trying voices:
 * then "go back", "back" and "previous" step back through the voices (SpeechVoiceTrial), and
 * anything else ends the trial.
 *
 * Phrases are listed in notes/customisation-ios-core.md.
 */

import Foundation
import UIKit

@MainActor
struct SpeechGrammar: SettingsGrammar {
  let area: SpeechSettings
  let trial: SpeechVoiceTrial
  /// The tool on screen, for "short answers here".
  var currentTool: @MainActor () -> ToolID? = { nil }
  var voiceOverRunning: @MainActor () -> Bool = { UIAccessibility.isVoiceOverRunning }
  var hasCloudKey: @MainActor () -> Bool = { CloudReading.shared.hasKey }

  static let nextVoice: Set<String> = [
    "try another voice", "another voice", "next voice", "try a different voice", "different voice", "change voice",
    "change the voice", "change your voice", "try voices", "try a new voice", "try the next voice",
  ]
  static let trialKeep: Set<String> = [
    "keep this one", "keep this voice", "keep that voice", "keep this", "keep that", "keep it", "this one", "i like this one",
    "use this one", "use this voice", "keep that one",
  ]
  static let trialBack: Set<String> = ["go back", "back", "previous voice", "the last voice", "last voice", "previous", "go back one"]
  static let trialCancel: Set<String> = ["cancel", "stop trying voices", "never mind", "keep my voice", "my old voice", "forget it"]
  static let defaultVoice: Set<String> = [
    "default voice", "reset voice", "reset the voice", "the usual voice", "original voice", "use the default voice",
    "use the british voice", "the apps voice", "the app voice",
  ]

  func handle(_ utterance: String) -> String? {
    let p = SettingsWords.phrase(utterance)
    guard !p.isEmpty else { return nil }
    if trial.isActive {
      if Self.trialKeep.contains(p) { return trial.keep() }
      if Self.trialBack.contains(p) { return trial.previous() }
      if Self.nextVoice.contains(p) { return trial.next() }
      if Self.trialCancel.contains(p) { return trial.cancel() }
      trial.end()
    }
    if Self.nextVoice.contains(p) { return trial.next() }
    if Self.defaultVoice.contains(p) { return area.setVoice(nil) }
    if let reply = rate(p) { return reply }
    if let reply = pitchAndPauses(p) { return reply }
    if let reply = preset(p) { return reply }
    if let reply = toolVerbosity(p) { return reply }
    return voices(p)
  }

  private func rate(_ p: String) -> String? {
    switch p {
    case "normal speed", "normal rate", "reset speed", "reset the speed", "normal speaking speed", "speak normally":
      return area.setRate(1)
    case "double speed", "twice as fast", "speak twice as fast": return area.setRate(2)
    case "half speed", "half as fast": return area.setRate(0.5)
    case "fastest", "as fast as you can", "fastest speed": return area.setRate(SpeechRateScale.maximum)
    case "slowest", "as slow as you can", "slowest speed": return area.setRate(SpeechRateScale.minimum)
    default: break
    }
    for prefix in ["speech rate", "speaking speed", "speed", "speech", "rate", "speak at", "talk at", "set speed to", "set the speed to"] {
      guard var rest = SettingsWords.rest(of: p, after: prefix) else { continue }
      if rest.hasSuffix(" times") { rest = String(rest.dropLast(6)) }
      if let number = SettingsWords.number(rest) { return outOfRange(number) ?? area.setRate(number) }
    }
    if p.hasSuffix(" times"), let number = SettingsWords.number(String(p.dropLast(6))) { return outOfRange(number) ?? area.setRate(number) }
    return nil
  }

  private func outOfRange(_ rate: Double) -> String? {
    guard rate < SpeechRateScale.minimum - 0.001 || rate > SpeechRateScale.maximum + 0.001 else { return nil }
    return "Speech goes from half speed to 3 times. Say a speed between those."
  }

  private func pitchAndPauses(_ p: String) -> String? {
    switch p {
    case "higher voice", "higher pitch", "raise the pitch", "pitch up", "speak higher", "a higher voice": return area.stepPitch(higher: true)
    case "lower voice", "lower pitch", "deeper voice", "lower the pitch", "pitch down", "speak lower", "a lower voice", "a deeper voice":
      return area.stepPitch(higher: false)
    case "normal pitch", "reset pitch", "reset the pitch", "normal voice pitch": return area.setPitch(1)
    case "longer pauses", "longer pause", "more pause", "more pauses", "pause longer", "longer gaps", "bigger pauses":
      return area.stepPause(longer: true)
    case "shorter pauses", "shorter pause", "less pause", "fewer pauses", "pause less", "shorter gaps", "smaller pauses":
      return area.stepPause(longer: false)
    case "no pauses", "no pause", "normal pauses", "no gaps", "reset pauses": return area.setPause(0)
    default: break
    }
    if let rest = SettingsWords.rest(of: p, after: "pitch"), let number = SettingsWords.number(rest) { return area.setPitch(number) }
    return nil
  }

  private func preset(_ p: String) -> String? {
    let words = p.replacingOccurrences(of: "use ", with: "").replacingOccurrences(of: " please", with: "")
    let names: [(SpeechPreset, [String])] = [
      (.brisk, ["brisk", "brisk speech", "brisk voice", "speech brisk", "brisk preset"]),
      (.normal, ["normal speech", "speech normal", "normal preset", "normal speaking"]),
      (.gentle, ["gentle", "gentle speech", "gentle voice", "speech gentle", "gentle preset"]),
      (.clearRate, ["clear speech rate", "slow and clear", "clear rate", "clear speech speed", "clear speech rate preset"]),
    ]
    for (preset, phrases) in names where phrases.contains(words) { return area.applyPreset(preset) }
    return nil
  }

  private static let verbosityWords: [String: Verbosity] = [
    "short": .short, "shorter": .short, "brief": .short, "normal": .normal, "medium": .normal, "detailed": .detailed,
    "long": .detailed, "longer": .detailed, "more detailed": .detailed,
  ]

  static let toolNames: [String: ToolID] = [
    "read text": .read, "reading": .read, "reading text": .read, "the reader": .read,
    "mail": .mail, "mail reader": .mail, "letters": .mail, "post": .mail, "the mail reader": .mail, "my mail": .mail,
    "labels": .labels, "labels and barcodes": .labels, "barcodes": .labels,
    "watch": .watch, "watch for text": .watch,
    "ask": .ask, "ask about the text": .ask, "questions": .ask,
    "light": .light, "light and colour": .light, "light and color": .light, "colour": .light, "colours": .light,
  ]

  static func tool(named words: String) -> ToolID? {
    let trimmed = words.hasPrefix("the ") && toolNames[words] == nil ? String(words.dropFirst(4)) : words
    return toolNames[trimmed]
  }

  /// "short answers for mail", "detailed answers here", "same answers everywhere",
  /// "main answers for mail".
  private func toolVerbosity(_ p: String) -> String? {
    switch p {
    case "same answers everywhere", "main answers everywhere", "one answer length everywhere", "clear tool answers",
      "every tool the same", "same answers for every tool":
      return area.clearToolVerbosity(nil)
    default: break
    }
    for joiner in [" answers for ", " answers in ", " answers on "] {
      guard let range = p.range(of: joiner) else { continue }
      let word = String(p[..<range.lowerBound])
      let target = String(p[range.upperBound...])
      if word == "main" || word == "usual" || word == "same" {
        return Self.tool(named: target).map { area.clearToolVerbosity($0) }
      }
      guard let verbosity = Self.verbosityWords[word], let tool = Self.tool(named: target) else { continue }
      return area.setVerbosity(verbosity, tool: tool)
    }
    if p.hasSuffix(" answers here"), let verbosity = Self.verbosityWords[String(p.dropLast(" answers here".count))] {
      guard let tool = currentTool() else { return "No tool is open. Say short answers for, then a tool's name." }
      return area.setVerbosity(verbosity, tool: tool)
    }
    if p.hasSuffix(" like everywhere else"), let tool = Self.tool(named: String(p.dropLast(" like everywhere else".count))) {
      return area.clearToolVerbosity(tool)
    }
    return nil
  }

  private func voices(_ p: String) -> String? {
    switch p {
    case "natural voice on", "turn on the natural voice", "turn the natural voice on", "use the natural voice":
      return area.setNaturalVoice(true, hasKey: hasCloudKey())
    case "natural voice off", "turn off the natural voice", "turn the natural voice off", "stop using the natural voice":
      return area.setNaturalVoice(false, hasKey: hasCloudKey())
    case "voiceover voice on", "voice over voice on", "use voiceovers voice", "use voice overs voice", "use the voiceover voice":
      return area.setVoiceOverVoice(true, voiceOverRunning: voiceOverRunning())
    case "voiceover voice off", "voice over voice off", "use the apps own voice", "use your own voice":
      return area.setVoiceOverVoice(false, voiceOverRunning: voiceOverRunning())
    default: return nil
    }
  }
}

@MainActor
struct TipsGrammar: SettingsGrammar {
  let area: TipsSettings

  func handle(_ utterance: String) -> String? {
    switch SettingsWords.phrase(utterance) {
    case "fewer tips", "less tips", "tips less often", "fewer reminders", "fewer nudges", "not so many tips":
      return area.setPacing(.fewer)
    case "normal tips", "tips on", "turn on tips", "turn tips on", "more tips", "spoken tips on", "turn on spoken tips":
      return area.setPacing(.normal)
    case "tips off", "no tips", "turn off tips", "turn tips off", "spoken tips off", "turn off spoken tips", "stop the tips",
      "no more tips", "no reminders":
      return area.setPacing(.off)
    default: return nil
    }
  }
}

@MainActor
struct DescriptionsGrammar: SettingsGrammar {
  let area: DescriptionSettings

  func handle(_ utterance: String) -> String? {
    switch SettingsWords.phrase(utterance) {
    case "short descriptions", "brief descriptions", "shorter descriptions": return area.setDetail(.short)
    case "normal descriptions", "medium descriptions": return area.setDetail(.normal)
    case "detailed descriptions", "more detailed descriptions", "long descriptions", "longer descriptions": return area.setDetail(.detailed)
    case "skip colours", "skip colors", "no colours", "no colors", "dont mention colours", "dont mention colors", "colours off", "colors off":
      return area.setMentionColours(false)
    case "mention colours", "mention colors", "say colours", "say colors", "colours on", "colors on":
      return area.setMentionColours(true)
    case "read text first", "read the text first", "text first", "always read text first": return area.setReadTextFirst(true)
    case "dont read text first", "dont read the text first", "text not first": return area.setReadTextFirst(false)
    case "clock face directions", "clock face", "use clock face", "use the clock face", "clock directions":
      return area.setDirections(.clockFace)
    case "left and right directions", "use left and right", "left right directions": return area.setDirections(.leftRight)
    default: return nil
    }
  }
}
