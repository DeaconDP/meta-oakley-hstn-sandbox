/*
 * AppVoice - the one voice the app speaks with
 *
 * The Announcer and TtsReply speak with a female British English voice, whatever the system
 * language or region. Choosing is VoiceSelection.choose, a pure function over VoiceDescriptor:
 * en-GB and female (by gender, or by known name when iOS reports no gender), best quality first,
 * then Serena, Kate, Stephanie and Martha in that order.
 *
 * A stock iPhone may have no such voice: the only en-GB voice on the Simulator's runtime is the
 * male Daniel, and iOS has no API to download one. So the fallback is any other en-GB voice, then
 * a woman's voice from another English accent, then any other English voice, and the user is told
 * once, by voice and on screen, how to download one.
 *
 * The choice is refreshed on AVSpeechSynthesizer.availableVoicesDidChangeNotification, so a voice
 * downloaded while the app runs is used from the next line on, without a relaunch.
 */

import AVFoundation
import Observation
import UIKit
import os

/// What selection needs to know about a voice. Lets the rules run without AVFoundation's voices.
struct VoiceDescriptor: Equatable, Sendable {
  enum Gender: Sendable {
    case female
    case male
    case unspecified
  }

  var name: String
  var identifier: String
  var language: String
  var gender: Gender
  /// AVSpeechSynthesisVoiceQuality's raw value: 1 default, 2 enhanced, 3 premium.
  var quality: Int
  /// A novelty or personal voice by trait. Identifier-based novelties are caught by selection.
  var isNovelty = false
}

/// How close the chosen voice is to what the app wants. Lower raw value is better.
enum VoiceMatch: Int, Comparable, Sendable {
  case britishFemale
  case britishOther
  case englishFemale
  case englishOther

  static func < (lhs: VoiceMatch, rhs: VoiceMatch) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct VoiceChoice: Equatable, Sendable {
  var voice: VoiceDescriptor
  var match: VoiceMatch

  var isBritishFemale: Bool { match == .britishFemale }
}

enum VoiceSelection {
  static let preferredNames = ["Serena", "Kate", "Stephanie", "Martha"]

  /// en-GB women's names, used only when iOS reports `.unspecified` for the voice's gender.
  static let knownBritishFemaleNames: Set<String> = ["Serena", "Kate", "Stephanie", "Martha"]

  /// Closest accents first, for the fallback when no British voice exists at all.
  static let fallbackLanguages = ["en-IE", "en-AU", "en-NZ", "en-ZA", "en-US", "en-CA", "en-IN"]

  /// The best usable voice, or nil if no English voice is installed.
  static func choose(from voices: [VoiceDescriptor]) -> VoiceChoice? {
    let candidates: [VoiceChoice] = voices.compactMap { voice in
      match(for: voice).map { VoiceChoice(voice: voice, match: $0) }
    }
    return candidates.min { isBetter($0, than: $1) }
  }

  private static func match(for voice: VoiceDescriptor) -> VoiceMatch? {
    guard isUsable(voice) else { return nil }
    let language = normalizedLanguage(voice.language)
    let female = isFemale(voice)
    if language == "en-GB" { return female ? .britishFemale : .britishOther }
    guard language == "en" || language.hasPrefix("en-") else { return nil }
    return female ? .englishFemale : .englishOther
  }

  private static func isBetter(_ lhs: VoiceChoice, than rhs: VoiceChoice) -> Bool {
    if lhs.match != rhs.match { return lhs.match < rhs.match }
    if lhs.voice.quality != rhs.voice.quality { return lhs.voice.quality > rhs.voice.quality }
    let lhsName = nameRank(lhs.voice)
    let rhsName = nameRank(rhs.voice)
    if lhsName != rhsName { return lhsName < rhsName }
    let lhsLanguage = languageRank(lhs.voice)
    let rhsLanguage = languageRank(rhs.voice)
    if lhsLanguage != rhsLanguage { return lhsLanguage < rhsLanguage }
    return lhs.voice.identifier < rhs.voice.identifier
  }

  /// Excludes novelty and personal voices. Eloquence (Flo, Sandy, Shelley, Grandma...) and the old
  /// Mac speech-synthesis set can report as ordinary voices, some of them female en-GB, but they
  /// are too robotic to read a book with, so they don't count as the British woman's voice.
  static func isUsable(_ voice: VoiceDescriptor) -> Bool {
    guard !voice.isNovelty else { return false }
    let identifier = voice.identifier.lowercased()
    return !identifier.contains(".eloquence.") && !identifier.contains(".speech.synthesis.voice.")
  }

  static func isFemale(_ voice: VoiceDescriptor) -> Bool {
    switch voice.gender {
    case .female: true
    case .male: false
    case .unspecified: knownBritishFemaleNames.contains(baseName(voice))
    }
  }

  /// "Voice: Serena, British".
  static func displayString(for voice: VoiceDescriptor) -> String {
    "Voice: \(baseName(voice)), \(accentName(language: voice.language))"
  }

  static func accentName(language: String) -> String {
    switch normalizedLanguage(language) {
    case "en-GB": "British"
    case "en-IE": "Irish"
    case "en-AU": "Australian"
    case "en-NZ": "New Zealand"
    case "en-ZA": "South African"
    case "en-US": "American"
    case "en-CA": "Canadian"
    case "en-IN": "Indian"
    default: language
    }
  }

  /// The once-only "how to download" notice applies when the app's own voice is what's heard and
  /// it isn't a British woman's.
  static func shouldOfferDownload(choice: VoiceChoice?, alreadyHeard: Bool, followsVoiceOver: Bool) -> Bool {
    !alreadyHeard && !followsVoiceOver && choice?.isBritishFemale != true
  }

  /// "Serena" from "Serena (Premium)". iOS names voices without the suffix; macOS with it.
  static func baseName(_ voice: VoiceDescriptor) -> String {
    voice.name.split(whereSeparator: { $0 == " " || $0 == "(" }).first.map(String.init) ?? voice.name
  }

  private static func nameRank(_ voice: VoiceDescriptor) -> Int {
    preferredNames.firstIndex(of: baseName(voice)) ?? preferredNames.count
  }

  private static func languageRank(_ voice: VoiceDescriptor) -> Int {
    fallbackLanguages.firstIndex(of: normalizedLanguage(voice.language)) ?? fallbackLanguages.count
  }

  /// "en_GB" and "EN-gb" are both "en-GB".
  static func normalizedLanguage(_ language: String) -> String {
    let parts = language.replacingOccurrences(of: "_", with: "-").split(separator: "-")
    guard let first = parts.first else { return language }
    return ([first.lowercased()] + parts.dropFirst().map { $0.uppercased() }).joined(separator: "-")
  }
}

@MainActor
@Observable
final class AppVoice {
  static let shared = AppVoice()

  /// The current choice; nil before the first lookup or with no English voice installed.
  private(set) var choice: VoiceChoice?

  /// The "how to download a British voice" text while it should be on screen. Bind a view to it.
  private(set) var downloadNotice: String?

  @ObservationIgnored private var cachedVoice: AVSpeechSynthesisVoice?
  @ObservationIgnored private var isLoaded = false
  @ObservationIgnored private var observer: NSObjectProtocol?
  @ObservationIgnored private let preferences = A11yPreferences.shared

  private static let logger = Logger(subsystem: "com.deaco.hstnbench", category: "AppVoice")

  private init() {
    observer = NotificationCenter.default.addObserver(
      forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshInBackground() }
    }
  }

  /// The voice to put on an utterance. The first lookup is slow enough to delay the first word, so
  /// prepare() runs it ahead of time; if that hasn't finished, it happens here.
  var voice: AVSpeechSynthesisVoice? {
    if !isLoaded { apply(Self.installedVoices()) }
    return cachedVoice ?? AVSpeechSynthesisVoice(language: "en-GB")
  }

  /// For settings: "Voice: Serena, British".
  var displayString: String {
    if preferences.useVoiceOverVoice, UIAccessibility.isVoiceOverRunning { return "Voice: VoiceOver's voice" }
    guard let choice else { return "Voice: system default" }
    return VoiceSelection.displayString(for: choice.voice)
  }

  /// Does the first lookup off the main thread, at launch.
  func prepare() {
    guard !isLoaded else { return }
    refreshInBackground()
  }

  private func refreshInBackground() {
    Task.detached(priority: .utility) { [weak self] in
      let voices = Self.installedVoices()
      await self?.apply(voices)
    }
  }

  nonisolated private static func installedVoices() -> [VoiceDescriptor] {
    AVSpeechSynthesisVoice.speechVoices().map { voice in
      let gender: VoiceDescriptor.Gender =
        switch voice.gender {
        case .female: .female
        case .male: .male
        default: .unspecified
        }
      return VoiceDescriptor(
        name: voice.name, identifier: voice.identifier, language: voice.language, gender: gender,
        quality: voice.quality.rawValue,
        isNovelty: voice.voiceTraits.contains(.isNoveltyVoice) || voice.voiceTraits.contains(.isPersonalVoice))
    }
  }

  private func apply(_ voices: [VoiceDescriptor]) {
    let new = VoiceSelection.choose(from: voices)
    let wasLoaded = isLoaded
    isLoaded = true
    guard !wasLoaded || new != choice else { return }
    let previous = choice
    choice = new
    cachedVoice = new.flatMap { AVSpeechSynthesisVoice(identifier: $0.voice.identifier) }
    if let new {
      let voice = new.voice
      Self.logger.info(
        "voice name=\(voice.name, privacy: .public) id=\(voice.identifier, privacy: .public) language=\(voice.language, privacy: .public) quality=\(voice.quality) match=\(String(describing: new.match), privacy: .public)"
      )
    } else {
      Self.logger.error("voice: no English voice is installed, using the system default")
    }
    if wasLoaded, let new, new.isBritishFemale, previous?.isBritishFemale != true {
      downloadNotice = nil
      preferences.voiceDownloadNoticeHeard = true
      Announcer.shared.say(SpokenMessage.voiceNowInstalled(name: VoiceSelection.baseName(new.voice)), interrupt: false)
    }
  }

  /// Once, ever: says and shows how to download a British woman's voice. A line cut off before its
  /// end comes back next launch, as with the disclaimer. Queued, so it follows the status line.
  func offerDownloadIfNeeded() {
    guard !LaunchOptions.isAutomatedTest else { return }
    _ = voice  // make sure the lookup has happened
    let followsVoiceOver = preferences.useVoiceOverVoice && UIAccessibility.isVoiceOverRunning
    guard
      VoiceSelection.shouldOfferDownload(
        choice: choice, alreadyHeard: preferences.voiceDownloadNoticeHeard, followsVoiceOver: followsVoiceOver)
    else { return }
    let current = choice.map { VoiceSelection.baseName($0.voice) }
    downloadNotice = SpokenMessage.voiceDownloadOnScreen(current: current)
    Announcer.shared.announce(SpokenMessage.voiceDownload(current: current), earcon: .attention, interrupt: false) {
      [weak self] finished in
      if finished { self?.preferences.voiceDownloadNoticeHeard = true }
    }
  }

  func dismissDownloadNotice() {
    downloadNotice = nil
    preferences.voiceDownloadNoticeHeard = true
  }
}
