/*
 * CustomiseCoreTests - Make it your own: the store (undo, keep that, lock, what's my setup,
 * resets, profiles, learned suggestions, export and import), the speech, tips and descriptions
 * areas, the rate migration, the settings grammars, and VoiceControl's settings hook
 * (notes/customisation-ios-core.md)
 *
 * Every test builds its own store, areas and preferences on an isolated defaults suite, so the
 * host app's real settings and its registered areas are untouched.
 */

import AVFoundation
@testable import CameraAccess
import Foundation
// ast-grep-ignore: swift-testing/swift/no-new-xctest
import XCTest

@MainActor
final class CustomiseCoreTests: XCTestCase {
  private var suiteName = ""
  private var defaults = UserDefaults()
  private var preferences: A11yPreferences!
  private var speech: SpeechSettings!
  private var tips: TipsSettings!
  private var descriptions: DescriptionSettings!
  private var store: SettingsStore!
  private var clock = Date(timeIntervalSince1970: 1000)
  private var said: [String] = []
  private var pendingYes: (@MainActor () -> Void)?
  private var pendingNo: (@MainActor () -> Void)?

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "CustomiseCoreTests.\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    relaunch()
  }

  override func tearDown() async throws {
    defaults.removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  /// A fresh app on the same saved defaults.
  private func relaunch() {
    preferences = A11yPreferences(defaults: defaults)
    speech = SpeechSettings(preferences: preferences)
    tips = TipsSettings(preferences: preferences)
    descriptions = DescriptionSettings(defaults: defaults)
    store = SettingsStore(
      defaults: defaults, areas: { [unowned self] in [speech, tips, descriptions] }, now: { [unowned self] in clock },
      ask: { [unowned self] yes, no in
        pendingYes = yes
        pendingNo = no
      },
      say: { [unowned self] in said.append($0) })
    let record: @MainActor (String, Data, String) -> Void = { [unowned self] in store.record($0, before: $1, description: $2) }
    let locked: @MainActor () -> Bool = { [unowned self] in store.isLocked }
    speech.record = record
    speech.isLocked = locked
    speech.noteTweak = { [unowned self] in store.noteTweak($0, suggestion: $1) }
    speech.voiceName = { _ in "Kate" }
    tips.record = record
    tips.isLocked = locked
    descriptions.record = record
    descriptions.isLocked = locked
  }

  private func byVoice(_ body: () -> String) -> String {
    store.voiceChange(body)
  }

  // MARK: Rate scale and migration

  func testRateScaleMapsTheEndsAndNormal() {
    XCTAssertEqual(SpeechRateScale.avRate(forMultiplier: 1), AVSpeechUtteranceDefaultSpeechRate)
    XCTAssertEqual(SpeechRateScale.avRate(forMultiplier: 0.5), AVSpeechUtteranceMinimumSpeechRate)
    XCTAssertEqual(SpeechRateScale.avRate(forMultiplier: 3), AVSpeechUtteranceMaximumSpeechRate)
    for rate in stride(from: Float(0), through: 1, by: 0.05) {
      XCTAssertEqual(SpeechRateScale.avRate(forMultiplier: SpeechRateScale.multiplier(forAVRate: rate)), rate, accuracy: 0.0001)
    }
    XCTAssertEqual(SpeechRateScale.multiplier(forAVRate: 0.6), 1.4, accuracy: 0.0001)
  }

  func testOldRateKeyMigratesWithoutLosingTheChoice() {
    defaults.set(Float(0.6), forKey: "a11y.speechRate")
    relaunch()
    XCTAssertEqual(preferences.speechRateMultiplier, 1.4, accuracy: 0.0001)
    XCTAssertEqual(preferences.speechRate, 0.6, accuracy: 0.0001)
    XCTAssertEqual(defaults.double(forKey: "a11y.speech.rate"), 1.4, accuracy: 0.0001)
    // The old key is still written, so an older build finds the same speed.
    preferences.speechRateMultiplier = 0.75
    XCTAssertEqual(defaults.float(forKey: "a11y.speechRate"), 0.25, accuracy: 0.0001)
    relaunch()
    XCTAssertEqual(preferences.speechRateMultiplier, 0.75, accuracy: 0.0001)
    // An older build ran in between and changed only the old key: its choice wins.
    defaults.set(Float(0.75), forKey: "a11y.speechRate")
    relaunch()
    XCTAssertEqual(preferences.speechRateMultiplier, 2, accuracy: 0.0001)
  }

  func testFasterAndSlowerStepOnThePortableScale() {
    XCTAssertEqual(speech.stepRate(faster: true), "Faster, 1.2 times.")
    XCTAssertEqual(preferences.speechRateMultiplier, 1.2, accuracy: 0.0001)
    _ = speech.stepRate(faster: false)
    XCTAssertEqual(speech.stepRate(faster: false), "Slower, 0.9 times.")
    preferences.speechRateMultiplier = 3
    XCTAssertEqual(speech.stepRate(faster: true), SpokenMessage.voiceFastest)
  }

  // MARK: Keep that

  func testVoiceChangeLastsTheSessionUnlessKept() {
    let line = byVoice { speech.stepRate(faster: true) }
    XCTAssertEqual(line, "Faster, 1.2 times.")
    XCTAssertEqual(store.unkeptAreas, ["speech"])
    XCTAssertEqual(store.takeFollowUp(), SettingsLines.keepHint)
    relaunch()
    XCTAssertEqual(preferences.speechRateMultiplier, 1.2, accuracy: 0.0001, "still 1.2 until start-up reverts")
    XCTAssertEqual(store.revertUnkeptChanges(), ["speech"])
    XCTAssertEqual(preferences.speechRateMultiplier, 1, accuracy: 0.0001)
    XCTAssertTrue(store.unkeptAreas.isEmpty)
  }

  func testKeepThatSurvivesARelaunch() {
    _ = byVoice { speech.stepRate(faster: true) }
    XCTAssertEqual(store.keep(), "Kept: speech Normal, but faster, 1.2 times.")
    XCTAssertEqual(store.keep(), SettingsLines.nothingToKeep)
    relaunch()
    XCTAssertEqual(store.revertUnkeptChanges(), [])
    XCTAssertEqual(preferences.speechRateMultiplier, 1.2, accuracy: 0.0001)
  }

  func testScreenChangeIsKeptAtOnceAndAdoptsEarlierVoiceChanges() {
    _ = byVoice { speech.setVerbosity(.short) }
    XCTAssertEqual(store.unkeptAreas, ["speech"])
    _ = speech.setRate(1.5)
    XCTAssertTrue(store.unkeptAreas.isEmpty)
    relaunch()
    store.revertUnkeptChanges()
    XCTAssertEqual(preferences.verbosity, .short)
    XCTAssertEqual(preferences.speechRateMultiplier, 1.5, accuracy: 0.0001)
  }

  // MARK: Undo

  func testUndoPutsChangesBackNewestFirst() {
    _ = byVoice { speech.stepRate(faster: true) }
    _ = byVoice { tips.setPacing(.fewer) }
    XCTAssertEqual(store.undo(), "Undone: fewer tips. Now tips at the defaults.")
    XCTAssertEqual(tips.pacing, .normal)
    XCTAssertTrue(store.undo().hasPrefix("Undone: faster, 1.2 times."))
    XCTAssertEqual(preferences.speechRateMultiplier, 1, accuracy: 0.0001)
    XCTAssertTrue(store.unkeptAreas.isEmpty, "back at the kept value, so nothing to keep")
    XCTAssertEqual(store.undo(), SettingsLines.nothingToUndo)
  }

  func testScreenStepsCloseTogetherAreOneUndo() {
    _ = speech.stepRate(faster: true)
    clock += 1
    _ = speech.stepRate(faster: true)
    XCTAssertEqual(store.undoStack.count, 1)
    clock += 10
    _ = speech.stepRate(faster: true)
    XCTAssertEqual(store.undoStack.count, 2)
    _ = store.undo()
    _ = store.undo()
    XCTAssertEqual(preferences.speechRateMultiplier, 1, accuracy: 0.0001)
  }

  // MARK: Lock

  func testLockStopsChangesUntilUnlocked() {
    _ = speech.setRate(1.4)
    XCTAssertEqual(store.lock(), SettingsLines.lockedNow)
    XCTAssertEqual(byVoice { speech.stepRate(faster: false) }, SettingsLines.locked)
    XCTAssertEqual(tips.setPacing(.off), SettingsLines.locked)
    XCTAssertEqual(store.undo(), SettingsLines.locked)
    XCTAssertEqual(store.reset(areaID: "speech"), SettingsLines.locked)
    XCTAssertEqual(store.importSetup("{}"), SettingsLines.locked)
    XCTAssertEqual(preferences.speechRateMultiplier, 1.4, accuracy: 0.0001)
    relaunch()
    XCTAssertTrue(store.isLocked, "the lock is saved")
    XCTAssertEqual(store.unlock(), SettingsLines.unlockedNow)
    XCTAssertEqual(store.unlock(), SettingsLines.alreadyUnlocked)
  }

  // MARK: What's my setup

  func testWhatsMySetupSpeaksOnlyDifferences() {
    XCTAssertEqual(store.whatsMySetup(), SettingsLines.allDefaults)
    _ = speech.setRate(1.2)
    _ = speech.setVerbosity(.detailed, tool: .mail)
    _ = tips.setPacing(.fewer)
    _ = byVoice { descriptions.setMentionColours(false) }
    let setup = store.whatsMySetup()
    XCTAssertTrue(setup.contains("speech Normal, but faster, 1.2 times"), setup)
    XCTAssertTrue(setup.contains("detailed answers in Mail reader"), setup)
    XCTAssertTrue(setup.contains("fewer tips"), setup)
    XCTAssertTrue(setup.contains("colours skipped"), setup)
    XCTAssertTrue(setup.contains("Not kept yet: descriptions."), setup)
    XCTAssertFalse(setup.contains("pitch"), setup)
  }

  func testPresetsAreDescribedAsNearestPlusTheDifference() {
    XCTAssertEqual(speech.presetDescription(), "Normal")
    _ = speech.applyPreset(.gentle)
    XCTAssertEqual(speech.presetDescription(), "Gentle")
    XCTAssertEqual(speech.currentPreset, .gentle)
    _ = speech.stepPitch(higher: true)
    XCTAssertEqual(speech.presetDescription(), "Gentle, but higher")
    _ = speech.applyPreset(.normal)
    _ = speech.stepPause(longer: true)
    XCTAssertEqual(speech.presetDescription(), "Normal, but longer pauses")
  }

  // MARK: Resets

  func testResetOneAreaIsUndoable() {
    _ = speech.setRate(2)
    _ = tips.setPacing(.off)
    XCTAssertEqual(store.reset(areaID: "speech"), "Speech is back to the defaults. Say undo to put it back.")
    XCTAssertEqual(preferences.speechRateMultiplier, 1, accuracy: 0.0001)
    XCTAssertEqual(tips.pacing, .off, "other areas untouched")
    _ = store.undo()
    XCTAssertEqual(preferences.speechRateMultiplier, 2, accuracy: 0.0001)
    XCTAssertEqual(store.reset(areaID: "sounds"), SettingsLines.noSuchArea("sounds"))
  }

  func testResetEverythingAsksFirstAndCanBeUndone() {
    _ = speech.setRate(2)
    _ = descriptions.setDirections(.clockFace)
    XCTAssertEqual(store.requestResetEverything(), SettingsLines.resetEverythingQuestion)
    XCTAssertEqual(preferences.speechRateMultiplier, 2, accuracy: 0.0001, "nothing changes before yes")
    pendingNo?()
    XCTAssertEqual(said.last, SettingsLines.nothingChanged)
    _ = store.requestResetEverything()
    pendingYes?()
    XCTAssertEqual(said.last, SettingsLines.resetEverythingDone)
    XCTAssertEqual(preferences.speechRateMultiplier, 1, accuracy: 0.0001)
    XCTAssertEqual(descriptions.directions, .leftRight)
    _ = store.undo()
    XCTAssertEqual(preferences.speechRateMultiplier, 2, accuracy: 0.0001)
    XCTAssertEqual(descriptions.directions, .clockFace)
  }

  // MARK: Profiles

  func testStarterProfilesSwitchAndKeepTheirOwnTweaks() {
    _ = speech.setRate(0.9)
    store.seedProfilesIfNeeded()
    XCTAssertEqual(store.activeProfile, "Home")
    let line = store.switchProfile(to: "out and about")
    XCTAssertTrue(line.hasPrefix("Out and about. Now "), line)
    XCTAssertEqual(preferences.verbosity, .short)
    XCTAssertEqual(preferences.speechRateMultiplier, 1.2, accuracy: 0.0001)
    XCTAssertEqual(tips.pacing, .fewer)
    XCTAssertEqual(descriptions.directions, .clockFace)
    XCTAssertEqual(store.whichProfile(), "You're using Out and about.")

    _ = byVoice { speech.stepRate(faster: true) }
    _ = store.keep()
    _ = store.switchProfile(to: "home")
    XCTAssertEqual(preferences.speechRateMultiplier, 0.9, accuracy: 0.0001, "Home is as it was")
    XCTAssertEqual(preferences.verbosity, .normal)
    _ = store.switchProfile(to: "Out and about")
    XCTAssertEqual(preferences.speechRateMultiplier, 1.4, accuracy: 0.0001, "the kept tweak stayed with the profile")

    _ = store.undo()
    XCTAssertEqual(store.activeProfile, "Home", "undo goes back to the profile before")
    XCTAssertEqual(preferences.speechRateMultiplier, 0.9, accuracy: 0.0001)
    XCTAssertTrue(store.switchProfile(to: "gym").hasPrefix("There's no profile called gym"))
  }

  func testSaveListAndDeleteProfiles() {
    store.seedProfilesIfNeeded()
    _ = speech.setRate(1.6)
    XCTAssertEqual(store.saveProfile(named: "walking"), "Saved as profile Walking. Say switch to Walking any time.")
    XCTAssertEqual(store.activeProfile, "Walking")
    XCTAssertTrue(store.listProfiles().contains("Walking"))
    XCTAssertEqual(store.deleteProfile(named: "walking"), "You're using Walking. Switch to another profile first.")
    _ = store.switchProfile(to: "Home")
    XCTAssertEqual(store.deleteProfile(named: "Walking"), "Deleted Walking. Say undo to bring it back.")
    XCTAssertFalse(store.profileNames.contains("Walking"))
    _ = store.undo()
    XCTAssertTrue(store.profileNames.contains("Walking"))
    relaunch()
    XCTAssertTrue(store.profileNames.contains("Walking"), "profiles are saved")
  }

  // MARK: Learned suggestions

  func testTheSameTweakThreeTimesAsksToMakeItTheDefault() {
    _ = byVoice { speech.setVerbosity(.short) }
    _ = store.takeFollowUp()
    _ = byVoice { speech.setVerbosity(.short) }
    XCTAssertNil(store.takeFollowUp())
    XCTAssertNil(pendingYes)
    _ = byVoice { speech.setVerbosity(.short) }
    XCTAssertEqual(store.takeFollowUp(), "That's three times. Make short answers the default? Say yes or no.")
    XCTAssertEqual(store.unkeptAreas, ["speech"], "nothing is kept before yes")
    pendingYes?()
    XCTAssertTrue(store.unkeptAreas.isEmpty)
    XCTAssertEqual(said.last, "Kept: short answers.")
  }

  func testScreenTweaksDontCountTowardsASuggestion() {
    for _ in 0..<4 { _ = speech.setVerbosity(.short) }
    XCTAssertNil(store.takeFollowUp())
    XCTAssertNil(pendingYes)
  }

  // MARK: Share and carry

  func testExportAndImportRoundTrip() throws {
    store.seedProfilesIfNeeded()
    _ = speech.setRate(1.4)
    _ = speech.setVerbosity(.detailed, tool: .labels)
    _ = tips.setPacing(.off)
    _ = descriptions.setDetail(.short)
    _ = store.saveProfile(named: "Kitchen")

    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: store.exportJSON()) as? [String: Any])
    XCTAssertEqual(json["schema"] as? Int, 1)
    XCTAssertEqual(json["kind"] as? String, "speakup.setup")
    let code = store.exportCode()
    XCTAssertTrue(code.hasPrefix("SPEAKUP1."))
    XCTAssertFalse(code.contains("+") || code.contains("/") || code.contains("="), "base64url")

    _ = store.resetEverything()
    XCTAssertEqual(preferences.speechRateMultiplier, 1, accuracy: 0.0001)
    let line = store.importSetup(" \(code)\n")
    XCTAssertTrue(line.hasPrefix("Setup imported. Now "), line)
    XCTAssertEqual(preferences.speechRateMultiplier, 1.4, accuracy: 0.0001)
    XCTAssertEqual(preferences.toolVerbosity["labels"], .detailed)
    XCTAssertEqual(tips.pacing, .off)
    XCTAssertEqual(descriptions.detail, .short)
    XCTAssertEqual(store.activeProfile, "Kitchen")

    _ = store.undo()
    XCTAssertEqual(preferences.speechRateMultiplier, 1, accuracy: 0.0001, "import is undoable")

    // The JSON form imports too.
    let text = String(decoding: store.exportJSON(), as: UTF8.self)
    XCTAssertTrue(store.importSetup(text).hasPrefix("Setup imported."))
  }

  func testImportRefusesWhatIsntASetup() {
    XCTAssertEqual(store.importSetup("hello"), "That isn't a SpeakUp setup code. Nothing changed.")
    XCTAssertEqual(
      store.importSetup(#"{"kind":"speakup.setup","schema":99,"areas":{}}"#),
      "That setup is from a newer version of SpeakUp. Update the app, then try again.")
    XCTAssertEqual(store.importSetup(#"{"schema":1,"areas":{}}"#), "That isn't a SpeakUp setup code. Nothing changed.")
    XCTAssertTrue(store.undoStack.isEmpty)
  }

  // MARK: Areas

  func testPerToolVerbosityIsAnOverrideOfTheMainOne() {
    var tool: String? = "mail"
    preferences.currentToolID = { tool }
    _ = speech.setVerbosity(.detailed, tool: .mail)
    XCTAssertEqual(preferences.effectiveVerbosity, .detailed)
    XCTAssertEqual(speech.setVerbosity(.short), "Short answers. Mail reader keeps its own.")
    XCTAssertEqual(preferences.effectiveVerbosity, .detailed)
    tool = "read"
    XCTAssertEqual(preferences.effectiveVerbosity, .short)
    _ = speech.clearToolVerbosity(.mail)
    tool = "mail"
    XCTAssertEqual(preferences.effectiveVerbosity, .short)
  }

  func testSnapshotsRestoreAndIgnoreMissingFields() throws {
    _ = speech.setRate(2.5)
    _ = speech.stepPitch(higher: true)
    let snapshot = speech.snapshot()
    speech.resetToDefaults()
    XCTAssertEqual(preferences.speechRateMultiplier, 1, accuracy: 0.0001)
    try speech.restore(snapshot)
    XCTAssertEqual(preferences.speechRateMultiplier, 2.5, accuracy: 0.0001)
    XCTAssertEqual(preferences.speechPitch, 1.1, accuracy: 0.0001)
    try speech.restore(Data(#"{"verbosity":"short","unknown":3}"#.utf8))
    XCTAssertEqual(preferences.verbosity, .short)
    XCTAssertEqual(preferences.speechRateMultiplier, 1, accuracy: 0.0001)
  }

  func testTipsPacingDrivesTheCoachSchedule() {
    _ = tips.setPacing(.fewer)
    XCTAssertTrue(preferences.voiceTipsEnabled)
    XCTAssertTrue(preferences.tipsFewer)
    XCTAssertEqual(VoiceCoachSchedule(timesHeard: 0, start: clock, fewer: true).gaps, VoiceCoachSchedule.fewerGaps)
    _ = tips.setPacing(.off)
    XCTAssertFalse(preferences.voiceTipsEnabled)
    XCTAssertEqual(tips.differencesFromDefaults(), ["tips off"])
  }

  func testDescriptionsPersist() {
    _ = descriptions.setDetail(.detailed)
    _ = descriptions.setReadTextFirst(false)
    relaunch()
    XCTAssertEqual(descriptions.detail, .detailed)
    XCTAssertFalse(descriptions.readTextFirst)
    XCTAssertEqual(descriptions.differencesFromDefaults(), ["detailed descriptions", "text not read first"])
  }
}

// MARK: - Grammars

@MainActor
final class SettingsGrammarTests: XCTestCase {
  private var suiteName = ""
  private var defaults = UserDefaults()
  private var preferences: A11yPreferences!
  private var speech: SpeechSettings!
  private var tips: TipsSettings!
  private var descriptions: DescriptionSettings!
  private var store: SettingsStore!
  private var trial: SpeechVoiceTrial!
  private var speechGrammar: SpeechGrammar!
  private var core: SettingsCoreGrammar!
  private var clipboard: String?
  private var openTool: ToolID?

  private let kate = VoiceDescriptor(name: "Kate", identifier: "voice.kate", language: "en-GB", gender: .female, quality: 2)
  private let daniel = VoiceDescriptor(name: "Daniel", identifier: "voice.daniel", language: "en-GB", gender: .male, quality: 1)
  private let karen = VoiceDescriptor(name: "Karen", identifier: "voice.karen", language: "en-AU", gender: .female, quality: 1)
  private let anna = VoiceDescriptor(name: "Anna", identifier: "voice.anna", language: "de-DE", gender: .female, quality: 3)

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "SettingsGrammarTests.\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    preferences = A11yPreferences(defaults: defaults)
    speech = SpeechSettings(preferences: preferences)
    tips = TipsSettings(preferences: preferences)
    descriptions = DescriptionSettings(defaults: defaults)
    store = SettingsStore(
      defaults: defaults, areas: { [unowned self] in [speech, tips, descriptions] }, ask: { _, _ in }, say: { _ in })
    let record: @MainActor (String, Data, String) -> Void = { [unowned self] in store.record($0, before: $1, description: $2) }
    for setter in [{ self.speech.record = record }, { self.tips.record = record }, { self.descriptions.record = record }] { setter() }
    speech.isLocked = { [unowned self] in store.isLocked }
    speech.noteTweak = { _, _ in }
    speech.voiceName = { [unowned self] id in [kate, daniel, karen].first { $0.identifier == id }?.name }
    trial = SpeechVoiceTrial(area: speech)
    trial.store = store
    trial.installedVoices = { [unowned self] in [daniel, anna, karen, kate] }
    trial.currentLanguage = { "en-GB" }
    trial.currentIdentifier = { [unowned self] in preferences.appVoiceIdentifier ?? "voice.kate" }
    speechGrammar = SpeechGrammar(area: speech, trial: trial, currentTool: { [unowned self] in openTool }, voiceOverRunning: { false }, hasCloudKey: { false })
    core = SettingsCoreGrammar(store: store, copy: { [unowned self] in clipboard = $0 }, paste: { [unowned self] in clipboard })
  }

  override func tearDown() async throws {
    defaults.removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  private func say(_ words: String) -> String? {
    store.voiceChange {
      speechGrammar.handle(words) ?? TipsGrammar(area: tips).handle(words) ?? DescriptionsGrammar(area: descriptions).handle(words)
        ?? core.handle(words)
    }
  }

  func testLeavesTheAppsOwnCommandsAlone() {
    for words in ["faster", "slower", "short answers", "normal answers", "detailed answers", "back", "go back", "stop", "read",
      "help", "switch to the phone", "use the phone", "yes", "no", "reset the torch", "what time is it"]
    {
      XCTAssertNil(say(words), words)
    }
  }

  func testSpeechPhrases() {
    XCTAssertEqual(say("speed 1.5"), "Speech at 1.5 times.")
    XCTAssertEqual(say("can you speak at one point two times please"), "Speech at 1.2 times.")
    XCTAssertEqual(say("2 times"), "Speech at 2 times.")
    XCTAssertEqual(say("speed 5"), "Speech goes from half speed to 3 times. Say a speed between those.")
    XCTAssertEqual(say("normal speed"), "Speech at normal speed.")
    XCTAssertEqual(say("higher voice"), "Higher voice, pitch 1.1.")
    XCTAssertEqual(say("longer pauses"), "Longer pauses, 0.2 seconds.")
    XCTAssertEqual(say("no pauses"), "No pauses.")
    XCTAssertEqual(say("brisk"), "Brisk speech, 1.4 times.")
    XCTAssertEqual(say("slow and clear"), "Clear speech rate, 0.75 times.")
    XCTAssertEqual(say("short answers for mail"), "Short answers in Mail reader.")
    XCTAssertEqual(preferences.toolVerbosity["mail"], .short)
    XCTAssertEqual(say("detailed answers here"), "No tool is open. Say short answers for, then a tool's name.")
    openTool = .labels
    XCTAssertEqual(say("detailed answers here"), "Detailed answers in Labels and barcodes.")
    XCTAssertEqual(say("mail like everywhere else"), "Mail reader back to your main answers, normal.")
    XCTAssertEqual(say("same answers everywhere"), "Every tool on your main answers, normal.")
    XCTAssertTrue(preferences.toolVerbosity.isEmpty)
    XCTAssertEqual(say("natural voice on"), "Natural reading voice on. It needs an OpenAI key, added in Settings, before it's heard.")
  }

  func testTryingVoicesByEar() throws {
    // English only, best quality first, British first: Kate (current), Daniel, Karen.
    XCTAssertEqual(trial.candidateList().map(\.name), ["Kate", "Daniel", "Karen"])
    XCTAssertTrue(try XCTUnwrap(say("try another voice")).hasPrefix("This is Daniel, British."))
    XCTAssertEqual(preferences.trialVoiceIdentifier, "voice.daniel")
    XCTAssertNil(preferences.appVoiceIdentifier, "only tried, not kept")
    XCTAssertEqual(say("go back"), "Back to your voice. Say try another voice to hear more.")
    XCTAssertNil(preferences.trialVoiceIdentifier)
    _ = say("next voice")
    XCTAssertTrue(try XCTUnwrap(say("try another voice")).hasPrefix("This is Karen, Australian."))
    XCTAssertTrue(try XCTUnwrap(say("go back")).hasPrefix("This is Daniel"))
    _ = say("try another voice")
    XCTAssertEqual(say("keep this one"), "Voice Karen.")
    XCTAssertEqual(preferences.appVoiceIdentifier, "voice.karen")
    XCTAssertNil(preferences.trialVoiceIdentifier)
    XCTAssertTrue(store.unkeptAreas.isEmpty, "keep this one is kept at once")
    XCTAssertNil(say("go back"), "go back is the app's again once the trial is over")
    XCTAssertTrue(try XCTUnwrap(say("undo")).hasPrefix("Undone: voice Karen."))
    XCTAssertNil(preferences.appVoiceIdentifier)
  }

  func testSomethingElseEndsATrial() {
    _ = say("try another voice")
    XCTAssertNotNil(preferences.trialVoiceIdentifier)
    XCTAssertEqual(say("fewer tips"), "Fewer tips. I'll wait a minute before a tip, and give two at most. Tips play in hands-free.")
    XCTAssertNil(preferences.trialVoiceIdentifier)
    XCTAssertNil(preferences.appVoiceIdentifier)
  }

  func testCorePhrases() throws {
    store.seedProfilesIfNeeded()
    _ = say("speed 2")
    XCTAssertEqual(say("keep that"), "Kept: speech Brisk, but faster, 2 times.")
    _ = say("tips off")
    XCTAssertEqual(say("put it back"), "Undone: tips off. Now tips at the defaults.")
    XCTAssertEqual(say("lock settings"), SettingsLines.lockedNow)
    XCTAssertEqual(say("higher voice"), SettingsLines.locked)
    XCTAssertEqual(say("unlock settings"), SettingsLines.unlockedNow)
    XCTAssertTrue(try XCTUnwrap(say("what's my setup")).contains("speech Brisk, but faster, 2 times"))
    XCTAssertEqual(say("reset speech"), "Speech is back to the defaults. Say undo to put it back.")
    XCTAssertEqual(say("reset my voice"), "Speech is back to the defaults. Say undo to put it back.")
    XCTAssertEqual(say("reset sounds"), SettingsLines.noSuchArea("sounds"))
    XCTAssertEqual(say("reset everything"), SettingsLines.resetEverythingQuestion)
    XCTAssertTrue(try XCTUnwrap(say("switch to reading")).hasPrefix("Reading. Now "))
    XCTAssertEqual(preferences.verbosity, .detailed)
    XCTAssertEqual(say("which profile"), "You're using Reading.")
    XCTAssertTrue(try XCTUnwrap(say("use the out and about profile")).hasPrefix("Out and about."))
    XCTAssertEqual(say("save as profile bus stop"), "Saved as profile Bus stop. Say switch to Bus stop any time.")
    XCTAssertTrue(try XCTUnwrap(say("list profiles")).contains("Bus stop"))
    XCTAssertEqual(say("settings help"), SettingsCoreGrammar.helpLine)
  }

  func testShareAndPasteByVoice() throws {
    _ = say("speed 1.5")
    XCTAssertEqual(say("paste a setup"), "There's nothing copied. Copy a SpeakUp setup code first.")
    XCTAssertTrue(try XCTUnwrap(say("copy my setup")).hasPrefix("Your setup code is copied."))
    XCTAssertTrue(try XCTUnwrap(clipboard).hasPrefix("SPEAKUP1."))
    // The code carries kept values only: the unkept 1.5 isn't in it.
    _ = say("keep that")
    _ = say("copy my setup")
    _ = say("reset speech")
    XCTAssertTrue(try XCTUnwrap(say("paste a setup")).hasPrefix("Setup imported."))
    XCTAssertEqual(preferences.speechRateMultiplier, 1.5, accuracy: 0.0001)
  }

  func testTipsAndDescriptionsPhrases() {
    XCTAssertEqual(say("no tips"), SpokenMessage.voiceTipsOff)
    XCTAssertEqual(tips.pacing, .off)
    XCTAssertEqual(say("tips on"), SpokenMessage.voiceTipsOn + " Tips play in hands-free.")
    XCTAssertEqual(say("skip colours"), "Skip colours. \(DescriptionSettings.notOnIPhoneYet)")
    XCTAssertFalse(descriptions.mentionColours)
    XCTAssertEqual(say("clock face directions"), "Clock-face directions. \(DescriptionSettings.notOnIPhoneYet)")
    XCTAssertEqual(say("detailed descriptions"), "Detailed descriptions. \(DescriptionSettings.notOnIPhoneYet)")
  }

  func testNumbersInWords() {
    XCTAssertEqual(SettingsWords.number("1 5"), 1.5)
    XCTAssertEqual(SettingsWords.number("one point five"), 1.5)
    XCTAssertEqual(SettingsWords.number("two and a half"), 2.5)
    XCTAssertEqual(SettingsWords.number("half"), 0.5)
    XCTAssertNil(SettingsWords.number("brisk"))
    XCTAssertEqual(SettingsWords.rate(1), "normal speed")
    XCTAssertEqual(SettingsWords.rate(1.25), "1.25 times")
  }
}

// MARK: - VoiceControl's hook

@MainActor
final class SettingsVoiceHookTests: XCTestCase {
  private var lines: [String] = []
  private var heard: [String] = []

  private func makeControl(preferences: A11yPreferences, route: @escaping @MainActor (String) -> String?) -> VoiceControl {
    var environment = VoiceControl.Environment(
      isInert: true, makePhoneListener: { _ in nil }, phoneLocale: { "en-GB" }, phoneMicPermission: { .granted },
      speechPermission: { .granted }, requestPermissions: {},
      say: { [unowned self] text, _, _, _ in lines.append(text) }, playEarcon: { _ in }, isSpeaking: { false },
      textBeingSpoken: { "" }, stopSpeech: {}, repeatLast: {}, hasReadSentences: { false }, micHearsVoiceOver: { _ in false },
      followsVoiceOverRate: { false }, setIdleTimerDisabled: { _ in }, glassesSpeechEnabled: { false }, now: { Date() })
    environment.routeSettings = route
    return VoiceControl(environment: environment, preferences: preferences)
  }

  func testSettingsRepliesComeFirstAndTheRestIsParsedAsBefore() throws {
    let suite = "SettingsVoiceHookTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = A11yPreferences(defaults: defaults)
    preferences.handsFree = true
    let control = makeControl(preferences: preferences) { [unowned self] text in
      heard.append(text)
      return text == "fewer tips" ? "Fewer tips." : nil
    }
    control.begin()
    control.setScreen(.camera) { _ in false }
    control.inject(transcript: "fewer tips")
    XCTAssertEqual(lines, ["Fewer tips."])
    control.inject(transcript: "reader short answers")
    XCTAssertEqual(heard.last, "short answers", "the wake word is taken off first")
    XCTAssertEqual(preferences.verbosity, .short, "unclaimed words still reach the app's commands")
    control.inject(transcript: "faster")
    XCTAssertEqual(lines.last, "Faster, 1.2 times.")
    XCTAssertEqual(preferences.speechRateMultiplier, 1.2, accuracy: 0.0001)
  }

  func testAWaitingQuestionGetsTheAnswerFirst() throws {
    let suite = "SettingsVoiceHookTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = A11yPreferences(defaults: defaults)
    preferences.handsFree = true
    var answered = false
    let control = makeControl(preferences: preferences) { _ in "claimed" }
    control.begin()
    control.setScreen(.camera) { _ in false }
    control.ask(yes: { answered = true }, no: {})
    control.inject(transcript: "yes")
    XCTAssertTrue(answered)
    XCTAssertFalse(lines.contains("claimed"))
  }
}
