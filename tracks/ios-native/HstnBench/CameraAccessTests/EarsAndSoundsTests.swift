/*
 * EarsAndSoundsTests - "Your ears" and "Sounds" (Make it your own), without real audio
 *
 * The areas in isolated defaults suites (snapshot/restore, differences from defaults, lock refusal,
 * undo records, persistence), the pan and side-cue maths, the Sounds rules the Announcer follows,
 * the listening check's ladder, and the grammars (phrases, ear-routing pattern, and that none of
 * them is taken by VoiceCommand or the settings core). AudioBusLatencyTests measures the earcon and
 * speech-bus timings on the simulator.
 */

import AVFoundation
@testable import CameraAccess
import Foundation
// ast-grep-ignore: swift-testing/swift/no-new-xctest
import XCTest

@MainActor
final class EarsAreaTests: XCTestCase {
  private var suiteName = ""
  private var defaults = UserDefaults()
  private var recorded: [(area: String, before: Data, description: String)] = []

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "EarsAreaTests.\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    recorded = []
    SettingsChanges.handler = { [weak self] area, before, description in
      MainActor.assumeIsolated { self?.recorded.append((area, before, description)) }
    }
    SettingsChanges.isLocked = { false }
  }

  override func tearDown() async throws {
    SettingsChanges.handler = nil
    SettingsChanges.isLocked = { false }
    defaults.removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  func testDefaultsHaveNoDifferences() {
    let area = EarsArea(defaults: defaults)
    XCTAssertEqual(area.values, EarsArea.Values())
    XCTAssertEqual(area.differencesFromDefaults(), [])
    XCTAssertEqual(EarsArea.areaID, "ears")
    XCTAssertEqual(area.spokenName, "your ears")
  }

  func testSnapshotRestoreRoundTrip() throws {
    let area = EarsArea(defaults: defaults)
    _ = area.moveBalance(steps: -2)
    _ = area.setRoute(.left, for: [.speech])
    _ = area.setRoute(.right, for: [.alert])
    _ = area.setUserMono(true)
    _ = area.setClearSpeech(true)
    let snapshot = area.snapshot()

    let other = EarsArea(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName + ".other")))
    try other.restore(snapshot)
    XCTAssertEqual(other.values, area.values)
    UserDefaults().removePersistentDomain(forName: suiteName + ".other")
  }

  func testRestoreKeepsDefaultsForMissingAndUnknownFields() throws {
    let area = EarsArea(defaults: defaults)
    try area.restore(Data(#"{"balance": 0.4, "speechRoute": "sideways", "future": 1}"#.utf8))
    XCTAssertEqual(area.values.balance, 0.4, accuracy: 0.001)
    XCTAssertEqual(area.values.speechRoute, .both)
    XCTAssertEqual(area.values.trebleGainDB, ClearSpeech.defaultTrebleGainDB)
  }

  func testDifferencesSpeakOnlyWhatChanged() {
    let area = EarsArea(defaults: defaults)
    _ = area.moveBalance(steps: -2)
    _ = area.setRoute(.left, for: [.speech])
    _ = area.setClearSpeech(true)
    XCTAssertEqual(area.differencesFromDefaults(), ["balance 40 percent left", "speech in your left ear", "clear speech on"])
    _ = area.setTrebleGain(9)
    XCTAssertTrue(area.differencesFromDefaults().contains("clear speech on, treble 9 decibels"))
  }

  func testEveryChangeIsRecordedWithTheSnapshotBefore() throws {
    let area = EarsArea(defaults: defaults)
    let before = area.snapshot()
    let line = area.moveBalance(steps: 1)
    XCTAssertEqual(line, "Sound 20 percent right.")
    XCTAssertEqual(recorded.count, 1)
    XCTAssertEqual(recorded.first?.area, "ears")
    XCTAssertEqual(recorded.first?.before, before)
    XCTAssertEqual(recorded.first?.description, line)
    // Undo puts it back.
    try area.restore(try XCTUnwrap(recorded.first?.before))
    XCTAssertEqual(area.values.balance, 0)
  }

  func testNoChangeIsNotRecorded() {
    let area = EarsArea(defaults: defaults)
    XCTAssertEqual(area.centreBalance(), "The sound is already in the centre.")
    XCTAssertTrue(recorded.isEmpty)
  }

  func testLockedRefusesAndChangesNothing() {
    SettingsChanges.isLocked = { true }
    let area = EarsArea(defaults: defaults)
    XCTAssertEqual(area.moveBalance(steps: -1), "Settings are locked. Say unlock settings to change them.")
    XCTAssertEqual(area.setClearSpeech(true), AudioCustomisation.lockedMessage)
    XCTAssertEqual(area.setRoute(.left, for: []), AudioCustomisation.lockedMessage)
    XCTAssertEqual(area.values, EarsArea.Values())
    XCTAssertTrue(recorded.isEmpty)
  }

  func testBalanceStepsAndEdges() {
    let area = EarsArea(defaults: defaults)
    for _ in 0..<5 { _ = area.moveBalance(steps: -1) }
    XCTAssertEqual(area.values.balance, -1, accuracy: 0.001)
    XCTAssertEqual(area.moveBalance(steps: -1), "The sound is already all the way left.")
    XCTAssertEqual(area.centreBalance(), "Sound centred.")
    XCTAssertEqual(EarsArea.balanceWords(-1), "all the way left")
    XCTAssertEqual(EarsArea.balanceWords(0.6), "60 percent right")
    XCTAssertEqual(EarsArea.steppedBalance(0.33), 0.4, accuracy: 0.001)
    XCTAssertEqual(EarsArea.steppedBalance(7), 1)
  }

  func testRouteEverythingAndPersistence() throws {
    let area = EarsArea(defaults: defaults)
    XCTAssertEqual(area.setRoute(.right, for: []), "Everything in your right ear.")
    let reloaded = EarsArea(defaults: defaults)
    XCTAssertEqual(reloaded.values.speechRoute, .right)
    XCTAssertEqual(reloaded.values.earconRoute, .right)
    XCTAssertEqual(reloaded.values.alertRoute, .right)
    XCTAssertEqual(area.setRoute(.left, for: [.speech, .earcon]), "Speech and sounds in your left ear.")
  }

  func testResetGoesBackToDefaults() {
    let area = EarsArea(defaults: defaults)
    _ = area.setUserMono(true)
    area.resetToDefaults()
    XCTAssertEqual(area.values, EarsArea.Values())
    XCTAssertEqual(EarsArea(defaults: defaults).values, EarsArea.Values())
  }

  func testSystemMonoChangeIsAnnouncedOnlyWhenItMatters() {
    let area = EarsArea(defaults: defaults, systemMono: false)
    XCTAssertFalse(area.isMono)
    XCTAssertEqual(area.systemMonoChanged(false), nil)
    XCTAssertNotNil(area.systemMonoChanged(true))
    XCTAssertTrue(area.isMono)
    // Already mono by the user's choice: the OS switching doesn't change anything heard.
    let userMono = EarsArea(defaults: defaults, systemMono: false)
    _ = userMono.setUserMono(true)
    XCTAssertNil(userMono.systemMonoChanged(true))
  }

  func testMonoNotesThatBalanceWontApply() {
    let area = EarsArea(defaults: defaults, systemMono: true)
    XCTAssertTrue(area.moveBalance(steps: -1).contains("Mono is on"))
  }
}

@MainActor
final class SoundsAreaTests: XCTestCase {
  private var suiteName = ""
  private var defaults = UserDefaults()
  private var recordedCount = 0

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "SoundsAreaTests.\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    recordedCount = 0
    SettingsChanges.handler = { [weak self] _, _, _ in MainActor.assumeIsolated { self?.recordedCount += 1 } }
    SettingsChanges.isLocked = { false }
  }

  override func tearDown() async throws {
    SettingsChanges.handler = nil
    SettingsChanges.isLocked = { false }
    defaults.removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  func testEarconsSwitchLivesInA11yPreferences() {
    let preferences = A11yPreferences(defaults: defaults)
    let area = SoundsArea(defaults: defaults, preferences: preferences)
    XCTAssertTrue(area.values.earconsOn)
    XCTAssertEqual(area.setEarcons(on: false), "Earcons off. I'll say things in words instead.")
    XCTAssertFalse(preferences.earconsEnabled)
    XCTAssertFalse(A11yPreferences(defaults: defaults).earconsEnabled)
    XCTAssertEqual(area.differencesFromDefaults(), ["earcons off"])
    // An existing "earcons off" from before the Sounds area carries over.
    XCTAssertFalse(SoundsArea(defaults: defaults).values.earconsOn)
  }

  func testSnapshotRestoreRoundTripIncludesEarcons() throws {
    let area = SoundsArea(defaults: defaults)
    _ = area.setEarcons(on: false)
    _ = area.changeEarconVolume(steps: -2)
    _ = area.changeSpeechVolume(steps: -1)
    _ = area.setEarconsOnly(true)
    _ = area.setSayInsteadOfBeeping(true)
    let snapshot = area.snapshot()
    area.resetToDefaults()
    XCTAssertEqual(area.values, SoundsArea.Values())
    try area.restore(snapshot)
    XCTAssertFalse(area.values.earconsOn)
    XCTAssertEqual(area.values.earconVolume, 0.6, accuracy: 0.001)
    XCTAssertEqual(area.values.speechVolume, 0.8, accuracy: 0.001)
    XCTAssertTrue(area.values.earconsOnly)
    XCTAssertTrue(area.values.sayInsteadOfBeeping)
    XCTAssertEqual(
      area.differencesFromDefaults(),
      ["earcons off", "earcons only for familiar actions", "saying sounds instead of beeping", "sounds at 60 percent",
       "voice at 80 percent"])
  }

  func testVolumeLimits() {
    let area = SoundsArea(defaults: defaults)
    XCTAssertTrue(area.changeSpeechVolume(steps: 1).contains("already as loud"))
    for _ in 0..<10 { _ = area.changeSpeechVolume(steps: -1) }
    XCTAssertEqual(area.values.speechVolume, SoundsArea.minimumSpeechVolume, accuracy: 0.001)
    XCTAssertTrue(area.changeSpeechVolume(steps: -1).contains("as quiet as I'll go"))
    for _ in 0..<10 { _ = area.changeEarconVolume(steps: -1) }
    XCTAssertEqual(area.values.earconVolume, SoundsArea.minimumEarconVolume, accuracy: 0.001)
    XCTAssertEqual(area.setEarconVolume(0.47), "Sounds 40 percent.")
  }

  func testLockedRefuses() {
    SettingsChanges.isLocked = { true }
    let area = SoundsArea(defaults: defaults)
    XCTAssertEqual(area.setEarcons(on: false), AudioCustomisation.lockedMessage)
    XCTAssertEqual(area.changeSpeechVolume(steps: 1), AudioCustomisation.lockedMessage)
    XCTAssertTrue(area.values.earconsOn)
    XCTAssertEqual(recordedCount, 0)
  }

  func testChangesAreRecorded() {
    let area = SoundsArea(defaults: defaults)
    _ = area.setEarconsOnly(true)
    _ = area.setEarconsOnly(true)
    XCTAssertEqual(recordedCount, 1)
  }
}

final class AudioShapeTests: XCTestCase {
  func testPanRouteWinsOverBalanceAndMonoCentres() {
    XCTAssertEqual(AudioShape.pan(route: .both, balance: -0.4, mono: false), -0.4)
    XCTAssertEqual(AudioShape.pan(route: .left, balance: 0.8, mono: false), -1)
    XCTAssertEqual(AudioShape.pan(route: .right, balance: -1, mono: false), 1)
    XCTAssertEqual(AudioShape.pan(route: .left, balance: 0.8, mono: true), 0)
    XCTAssertEqual(AudioShape.pan(route: .both, balance: 3, mono: false), 1)
  }

  func testPanPerKind() {
    var shape = AudioShape()
    shape.balance = 0.2
    shape.alertRoute = .left
    XCTAssertEqual(shape.pan(for: .speech), 0.2, accuracy: 0.001)
    XCTAssertEqual(shape.pan(for: .alert), -1)
    XCTAssertEqual(Earcon.error.soundKind, .alert)
    XCTAssertEqual(Earcon.done.soundKind, .earcon)
  }

  func testSpeechNeedsBusOnlyForPanOrClearSpeech() {
    var shape = AudioShape()
    XCTAssertFalse(shape.speechNeedsBus)
    shape.speechVolume = 0.6
    XCTAssertFalse(shape.speechNeedsBus)
    shape.balance = -0.2
    XCTAssertTrue(shape.speechNeedsBus)
    shape.mono = true
    XCTAssertFalse(shape.speechNeedsBus)
    shape.clearSpeech = ClearSpeech(trebleGainDB: 6)
    XCTAssertTrue(shape.speechNeedsBus)
    XCTAssertEqual(shape.speechRate(0.5), 0.5 * ClearSpeech.rateFactor, accuracy: 0.0001)
  }

  func testSideCueFallsBackToPitchWithMonoOrOneEarAlerts() {
    var shape = AudioShape()
    XCTAssertEqual(shape.sideCue(for: .left), .pan(-SideCue.panAmount))
    XCTAssertEqual(shape.sideCue(for: .right), .pan(SideCue.panAmount))
    XCTAssertEqual(shape.sideCue(for: .ahead), .plain)
    shape.mono = true
    XCTAssertEqual(shape.sideCue(for: .left), .pitch(SideCue.leftPitch))
    XCTAssertEqual(shape.sideCue(for: .right), .pitch(SideCue.rightPitch))
    shape.mono = false
    shape.alertRoute = .right
    XCTAssertEqual(shape.sideCue(for: .left), .pitch(SideCue.leftPitch))
  }

  func testWatchCueUsesTheSpotsSide() {
    let left = WatchSpot(text: "42", x: 0.1, heightFraction: 0.1)
    XCTAssertEqual(WatchSideCue.cue(for: left, camera: .phone, shape: AudioShape()), .pan(-SideCue.panAmount))
    var mono = AudioShape()
    mono.mono = true
    XCTAssertEqual(WatchSideCue.cue(for: left, camera: .phone, shape: mono), .pitch(SideCue.leftPitch))
  }

  func testPitchedEarconNotesScale() {
    let scaled = AudioBus.scaled(Earcon.attention.notes, by: 1.25)
    XCTAssertEqual(scaled.first?.from ?? 0, 1319 * 1.25, accuracy: 0.01)
    XCTAssertEqual(scaled.count, Earcon.attention.notes.count)
  }

  @MainActor
  func testBuildCombinesAreasAndPreview() {
    var ears = EarsArea.Values()
    ears.userMono = true
    ears.clearSpeech = true
    ears.trebleGainDB = 9
    var sounds = SoundsArea.Values()
    sounds.speechVolume = 0.8
    let shape = AudioShape.build(ears: ears, sounds: sounds, systemMono: false)
    XCTAssertTrue(shape.mono)
    XCTAssertEqual(shape.clearSpeech, ClearSpeech(trebleGainDB: 9))
    XCTAssertEqual(shape.speechVolume, 0.8, accuracy: 0.001)
    let preview = AudioShape.build(ears: EarsArea.Values(), sounds: sounds, systemMono: true, previewTrebleGainDB: 3)
    XCTAssertEqual(preview.clearSpeech, ClearSpeech(trebleGainDB: 3))
    XCTAssertTrue(preview.mono)
  }

  func testSpeechBusRouting() {
    var shaped = AudioShape()
    shaped.clearSpeech = ClearSpeech(trebleGainDB: 6)
    XCTAssertFalse(SpeechBusSpeaker.shouldRoute(routing: .whenShaped, broken: false, shape: AudioShape()))
    XCTAssertTrue(SpeechBusSpeaker.shouldRoute(routing: .whenShaped, broken: false, shape: shaped))
    XCTAssertFalse(SpeechBusSpeaker.shouldRoute(routing: .whenShaped, broken: true, shape: shaped))
    XCTAssertFalse(SpeechBusSpeaker.shouldRoute(routing: .off, broken: false, shape: shaped))
    XCTAssertTrue(SpeechBusSpeaker.shouldRoute(routing: .always, broken: false, shape: AudioShape()))
  }
}

final class SoundsPolicyTests: XCTestCase {
  func testDefaultPlaysEarconThenSpeaks() {
    let plan = SoundsPolicy.plan(text: "Ready", kind: .status, earcon: .ready, situation: SoundsSituation())
    XCTAssertEqual(plan, .speak(earcon: .ready, prefix: nil))
  }

  func testEarconsOffSpeaksWithoutTone() {
    let plan = SoundsPolicy.plan(text: "Ready", kind: .status, earcon: .ready, situation: SoundsSituation(earconsOn: false))
    XCTAssertEqual(plan, .speak(earcon: nil, prefix: nil))
  }

  func testEarconsOnlyAppliesToStatusLinesWithAnEarcon() {
    let situation = SoundsSituation(earconsOnly: true)
    XCTAssertEqual(SoundsPolicy.plan(text: "Done", kind: .status, earcon: .done, situation: situation), .earconOnly(.done))
    XCTAssertEqual(
      SoundsPolicy.plan(text: "A red mug", kind: .reply, earcon: .done, situation: situation), .speak(earcon: .done, prefix: nil))
    XCTAssertEqual(
      SoundsPolicy.plan(text: "Hello", kind: .status, earcon: nil, situation: situation), .speak(earcon: nil, prefix: nil))
    // With earcons off, earcons only would be silence, so the words stay.
    var off = situation
    off.earconsOn = false
    XCTAssertEqual(SoundsPolicy.plan(text: "Done", kind: .status, earcon: .done, situation: off), .speak(earcon: nil, prefix: nil))
  }

  func testSayInsteadOfBeeping() {
    let situation = SoundsSituation(sayInsteadOfBeeping: true)
    XCTAssertEqual(
      SoundsPolicy.plan(text: "Page read.", kind: .status, earcon: .done, situation: situation),
      .speak(earcon: nil, prefix: "Finished"))
    XCTAssertEqual(SoundsPolicy.spokenInsteadOfTone(.error, situation: situation), "Problem")
    // Microphone and waiting tones stay tones.
    XCTAssertNil(SoundsPolicy.spokenInsteadOfTone(.listening, situation: situation))
    XCTAssertNil(SoundsPolicy.spokenInsteadOfTone(.working, situation: situation))
    XCTAssertNil(SoundsPolicy.spokenInsteadOfTone(.error, situation: SoundsSituation()))
  }

  func testSpokenMeaningsAreNotVoiceCommands() {
    for earcon in Earcon.allCases {
      guard let meaning = earcon.spokenMeaning else { continue }
      let result = VoiceCommandParser.parse(meaning, context: VoiceContext(screen: .camera, addressed: true, awaitingAnswer: true))
      if case .command(let command) = result { XCTFail("\"\(meaning)\" is the command \(command)") }
    }
  }

  func testConversationModeKeepsQuietExceptItsOwnLines() {
    let situation = SoundsSituation(conversation: true)
    XCTAssertEqual(SoundsPolicy.plan(text: "Ready", kind: .status, earcon: .ready, situation: situation), .earconOnly(.ready))
    XCTAssertEqual(SoundsPolicy.plan(text: "A long answer", kind: .reply, earcon: nil, situation: situation), .drop)
    XCTAssertEqual(
      SoundsPolicy.plan(text: ConversationMode.startLine, kind: .status, earcon: nil, situation: situation),
      .speak(earcon: nil, prefix: nil))
    XCTAssertEqual(
      SoundsPolicy.plan(text: ConversationMode.endLine, kind: .status, earcon: nil, situation: situation),
      .speak(earcon: nil, prefix: nil))
  }

  @MainActor
  func testConversationModeAnnouncedBothWays() {
    let mode = ConversationMode()
    XCTAssertEqual(mode.start(stopSpeech: false), ConversationMode.startLine)
    XCTAssertTrue(mode.isActive)
    XCTAssertEqual(mode.start(stopSpeech: false), ConversationMode.alreadyOn)
    mode.noteHeldBack()
    XCTAssertEqual(mode.end(), ConversationMode.endLineMissed)
    XCTAssertFalse(mode.isActive)
    XCTAssertEqual(mode.end(), ConversationMode.alreadyOff)
    _ = mode.start(stopSpeech: false)
    XCTAssertEqual(mode.end(), ConversationMode.endLine)
  }
}

final class ClarityLadderTests: XCTestCase {
  func testClimbsWhileBWins() {
    var ladder = ClarityLadder(start: 6)
    XCTAssertEqual(ladder.pair?.a, 6)
    XCTAssertEqual(ladder.pair?.b, 9)
    ladder.choose(.b)
    XCTAssertEqual(ladder.pair?.a, 9)
    XCTAssertEqual(ladder.pair?.b, 12)
    ladder.choose(.b)
    // Top of the scale after moving: done.
    XCTAssertTrue(ladder.isDone)
    XCTAssertEqual(ladder.current, 12)
  }

  func testTriesDownWhenAWinsFirst() {
    var ladder = ClarityLadder(start: 6)
    ladder.choose(.a)
    XCTAssertFalse(ladder.isDone)
    XCTAssertEqual(ladder.pair?.b, 3)
    ladder.choose(.b)
    XCTAssertEqual(ladder.current, 3)
    ladder.choose(.a)
    XCTAssertTrue(ladder.isDone)
    XCTAssertEqual(ladder.current, 3)
  }

  func testStopsWhenAWinsAfterAMoveOrOnSame() {
    var ladder = ClarityLadder(start: 6)
    ladder.choose(.b)
    ladder.choose(.a)
    XCTAssertTrue(ladder.isDone)
    XCTAssertEqual(ladder.current, 9)

    var same = ClarityLadder(start: 6)
    same.choose(.same)
    XCTAssertTrue(same.isDone)
    XCTAssertEqual(same.current, 6)
  }

  func testStartAtTheTopTurnsRound() {
    var ladder = ClarityLadder(start: 12)
    XCTAssertEqual(ladder.pair?.b, 9)
    ladder.choose(.b)
    ladder.choose(.b)
    XCTAssertEqual(ladder.current, 6)
  }

  func testRoundsAreCapped() {
    var ladder = ClarityLadder(steps: [0, 1, 2, 3, 4, 5, 6, 7, 8], start: 0)
    for _ in 0..<10 { ladder.choose(.b) }
    XCTAssertTrue(ladder.isDone)
    XCTAssertEqual(ladder.rounds, ClarityLadder.maxRounds)
    XCTAssertEqual(ladder.current, 4)
  }
}

@MainActor
final class EarsAndSoundsGrammarTests: XCTestCase {
  private var suiteName = ""
  private var defaults = UserDefaults()

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "EarsAndSoundsGrammarTests.\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    SettingsChanges.isLocked = { false }
  }

  override func tearDown() async throws {
    SettingsChanges.isLocked = { false }
    defaults.removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  func testTheAskedForPhrases() {
    XCTAssertEqual(SoundsGrammar.action(for: "Earcons off"), .earconsOff)
    XCTAssertEqual(SoundsGrammar.action(for: "quieter sounds, please"), .quieterSounds)
    XCTAssertEqual(SoundsGrammar.action(for: "Reader, louder voice"), .louderVoice)
    XCTAssertEqual(SoundsGrammar.action(for: "earcons only"), .earconsOnlyOn)
    XCTAssertEqual(SoundsGrammar.action(for: "Say it instead of beeping."), .sayInsteadOn)
    XCTAssertEqual(EarsGrammar.action(for: "Move it left a bit"), .balanceLeft)
    XCTAssertEqual(EarsGrammar.action(for: "centre the sound"), .centre)
    XCTAssertEqual(EarsGrammar.action(for: "I use mono"), .monoOn)
    XCTAssertEqual(EarsGrammar.action(for: "clear speech on"), .clearSpeechOn)
    XCTAssertEqual(EarsGrammar.action(for: "Someone's talking to me"), .conversationOn)
    XCTAssertEqual(EarsGrammar.action(for: "check clear speech"), .checkClearSpeech)
    XCTAssertNil(SoundsGrammar.action(for: "read this"))
    XCTAssertNil(EarsGrammar.action(for: "read this"))
  }

  func testEarRoutingPattern() {
    XCTAssertEqual(EarsGrammar.action(for: "speech in my left ear"), .route([.speech], .left))
    XCTAssertEqual(EarsGrammar.action(for: "put the voice in the right ear"), .route([.speech], .right))
    XCTAssertEqual(EarsGrammar.action(for: "alerts to my left ear"), .route([.alert], .left))
    XCTAssertEqual(EarsGrammar.action(for: "sounds and alerts in my right ear"), .route([.earcon, .alert], .right))
    XCTAssertEqual(EarsGrammar.action(for: "everything in both ears"), .route([], .both))
    XCTAssertEqual(EarsGrammar.action(for: "earcons in both"), .route([.earcon], .both))
    XCTAssertNil(EarsGrammar.action(for: "speech in my left"))
    XCTAssertNil(EarsGrammar.action(for: "the bus in my left ear"))
    XCTAssertNil(EarsGrammar.action(for: "sounds on"))
  }

  func testHandleChangesTheArea() {
    let ears = EarsArea(defaults: defaults)
    let sounds = SoundsArea(defaults: defaults)
    XCTAssertEqual(EarsGrammar(area: ears).handle("move it left a bit"), "Sound 20 percent left.")
    XCTAssertEqual(EarsGrammar(area: ears).handle("speech in my right ear"), "Speech in your right ear.")
    XCTAssertEqual(ears.values.speechRoute, .right)
    XCTAssertEqual(SoundsGrammar(area: sounds).handle("quieter sounds"), "Sounds 80 percent.")
    XCTAssertNil(SoundsGrammar(area: sounds).handle("hello there"))
    SettingsChanges.isLocked = { true }
    XCTAssertEqual(SoundsGrammar(area: sounds).handle("earcons off"), AudioCustomisation.lockedMessage)
    XCTAssertEqual(EarsGrammar(area: ears).handle("centre the sound"), AudioCustomisation.lockedMessage)
  }

  /// Phrases the settings core claims (customisation roadmap C0) and examples of its patterns.
  private let corePhrases = [
    "faster", "slower", "undo", "keep that", "lock settings", "unlock settings", "whats my setup", "reset speech",
    "reset sounds", "reset your ears", "switch to home", "shorter", "more detail",
  ]

  func testNoPhraseCollidesWithVoiceCommandsOrTheCore() {
    let ours = SoundsGrammar.allPhrases + EarsGrammar.allPhrases
    XCTAssertEqual(Set(ours).count, ours.count, "a phrase is in two places")
    let contexts = [
      VoiceContext(screen: .camera, hasReadSentences: true, addressed: true, awaitingAnswer: true),
      VoiceContext(screen: .home, addressed: true, awaitingAnswer: true),
      VoiceContext(screen: .welcome, addressed: true),
    ]
    for phrase in ours {
      for context in contexts {
        if case .command(let command) = VoiceCommandParser.parse(phrase, context: context) {
          XCTFail("\"\(phrase)\" is also the voice command \(command)")
        }
      }
      XCTAssertFalse(corePhrases.contains(phrase), "\"\(phrase)\" belongs to the settings core")
    }
    for phrase in corePhrases {
      XCTAssertNil(SoundsGrammar.action(for: phrase), phrase)
      XCTAssertNil(EarsGrammar.action(for: phrase), phrase)
    }
  }

  func testStateOnlyPhrasesNeedTheirState() {
    let ears = EarsArea(defaults: defaults)
    XCTAssertFalse(ConversationMode.shared.isActive)
    XCTAssertFalse(ClarityCheck.shared.isRunning)
    XCTAssertNil(EarsGrammar(area: ears).handle("carry on"))
    XCTAssertNil(EarsGrammar(area: ears).handle("b"))
    XCTAssertNil(EarsGrammar(area: ears).handle("stop"))
  }
}

/// Timings on the simulator: the earcon budget with the bus in place, and the speech bus's first
/// buffer. Numbers are printed for notes/customisation-ios-ears.md.
@MainActor
final class AudioBusLatencyTests: XCTestCase {
  func testEarconsStayWithinTheBudget() async throws {
    EarconPlayer.shared.prepare()
    var samples: [Double] = []
    for _ in 0..<5 {
      AudioBusMetrics.update { $0.earconToScheduleMs = nil }
      EarconPlayer.shared.play(.heard)
      try await waitFor { AudioBusMetrics.latest.earconToScheduleMs != nil }
      samples.append(try XCTUnwrap(AudioBusMetrics.latest.earconToScheduleMs))
      try await Task.sleep(for: .milliseconds(150))
    }
    let output = AudioBusMetrics.latest.outputLatencyMs ?? 0
    let worst = samples.dropFirst().max() ?? samples[0]
    NSLog("%@", "LATENCY earcon trigger->scheduled ms: \(samples.map { String(format: "%.2f", $0) }) output latency ms: \(String(format: "%.1f", output))")
    // The first may include engine start; after that, trigger to sound must stay under 100 ms.
    XCTAssertLessThan(worst + output, 100)
  }

  func testSpeechBusFirstAudioAgainstTheDirectPath() async throws {
    EarconPlayer.shared.prepare()
    // A fixed voice: AppVoice's first lookup can stall for minutes on a fresh simulator.
    let voice = AVSpeechSynthesisVoice(language: "en-GB")
    let text = "The bus is on the left."
    let directMs = try await DirectSpeechProbe().firstWordMs(text, voice: voice)

    let speaker = SpeechBusSpeaker.shared
    let previous = speaker.routing
    speaker.routing = .always
    defer { speaker.routing = previous }
    await A11yAudioSessionTestHold.begin()
    var lines: [String] = []
    for run in ["cold", "warm", "warm"] {
      AudioBusMetrics.update {
        $0.speechToFirstBufferMs = nil
        $0.speechToPlayMs = nil
      }
      let utterance = AVSpeechUtterance(string: text)
      utterance.voice = voice
      let result = SpeechResult()
      speaker.speak(utterance, onStart: { _ in }, onEnd: { result.ended = $0 }, fallback: { result.fellBack = true })
      try await waitFor(timeout: 15) { result.ended != nil || result.fellBack }
      XCTAssertFalse(result.fellBack, "the bus fell back to the direct path")
      XCTAssertEqual(result.ended, true)
      let timings = AudioBusMetrics.latest
      XCTAssertNotNil(timings.speechToPlayMs)
      lines.append("\(run) first buffer \(timings.speechToFirstBufferMs.map { String(format: "%.1f", $0) } ?? "none") play \(timings.speechToPlayMs.map { String(format: "%.1f", $0) } ?? "none")")
    }
    await A11yAudioSessionTestHold.end()
    NSLog("%@", "LATENCY speech direct didStart ms: \(String(format: "%.1f", directMs)); bus ms: \(lines.joined(separator: "; ")); output ms: \(String(format: "%.1f", AudioBusMetrics.latest.outputLatencyMs ?? 0))")
  }

  private func waitFor(timeout: TimeInterval = 3, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      if Date() > deadline { throw XCTSkip("timed out waiting") }
      try await Task.sleep(for: .milliseconds(5))
    }
  }
}

@MainActor
private final class SpeechResult {
  var ended: Bool?
  var fellBack = false
}

/// Takes and releases A11yAudioSession's speech hold, as the Announcer does around a line.
enum A11yAudioSessionTestHold {
  static func begin() async {
    let audio = A11yAudioSession.shared
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      audio.queue.async {
        audio.beginSpeech()
        continuation.resume()
      }
    }
  }

  static func end() async {
    let audio = A11yAudioSession.shared
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      audio.queue.async {
        audio.endSpeech()
        continuation.resume()
      }
    }
  }
}

/// Times AVSpeechSynthesizer.speak to its did-start callback; -1 if it never starts within 8 s.
private final class DirectSpeechProbe: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
  private let synthesizer = AVSpeechSynthesizer()
  private var continuation: CheckedContinuation<Double, Never>?
  private var startedAt: UInt64 = 0

  @MainActor
  func firstWordMs(_ text: String, voice: AVSpeechSynthesisVoice?) async throws -> Double {
    synthesizer.delegate = self
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = voice
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(8))
      self.finish(-1)
    }
    return await withCheckedContinuation { continuation in
      self.continuation = continuation
      startedAt = DispatchTime.now().uptimeNanoseconds
      synthesizer.speak(utterance)
    }
  }

  @MainActor
  private func finish(_ ms: Double) {
    continuation?.resume(returning: ms)
    continuation = nil
    synthesizer.stopSpeaking(at: .immediate)
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
    let ms = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
    Task { @MainActor in self.finish(ms) }
  }
}
