/*
 * VoiceTests - the app's voice choice, the command parser, the listener rules, VoiceControl with
 * fake listeners, and GlassesSpeechListener against MockDeviceKit's Speech
 *
 * PhoneSpeechListener isn't here: it needs a real mic and recogniser (notes/a11y-device-test.md).
 */

import AVFoundation
@testable import CameraAccess
import Foundation
import MWDATCore
import MWDATMockDevice
import SwiftUI
// ast-grep-ignore: swift-testing/swift/no-new-xctest
import XCTest

private func voice(
  _ name: String, _ language: String = "en-GB", gender: VoiceDescriptor.Gender = .female, quality: Int = 1, id: String? = nil
) -> VoiceDescriptor {
  VoiceDescriptor(
    name: name, identifier: id ?? "com.apple.voice.compact.\(language).\(name)", language: language, gender: gender, quality: quality)
}

final class VoiceSelectionTests: XCTestCase {
  private let daniel = voice("Daniel", gender: .male)
  private let samantha = voice("Samantha", "en-US")

  func testStockPhoneFallsBackToDanielAndNeedsTheNotice() {
    let choice = VoiceSelection.choose(from: [daniel, samantha, voice("Tessa", "en-ZA")])
    XCTAssertEqual(choice?.voice.name, "Daniel")
    XCTAssertEqual(choice?.match, .britishOther)
    XCTAssertEqual(choice?.isBritishFemale, false)
  }

  func testBritishFemaleBeatsAMaleVoiceOfBetterQuality() {
    let choice = VoiceSelection.choose(from: [voice("Daniel", gender: .male, quality: 3), voice("Kate")])
    XCTAssertEqual(choice?.voice.name, "Kate")
    XCTAssertEqual(choice?.match, .britishFemale)
  }

  func testBestQualityThenPreferredName() {
    XCTAssertEqual(VoiceSelection.choose(from: [voice("Serena"), voice("Kate", quality: 2)])?.voice.name, "Kate")
    XCTAssertEqual(VoiceSelection.choose(from: [voice("Martha", quality: 2), voice("Serena", quality: 2)])?.voice.name, "Serena")
    XCTAssertEqual(VoiceSelection.choose(from: [voice("Unknown"), voice("Stephanie")])?.voice.name, "Stephanie")
  }

  func testUnspecifiedGenderCountsAsFemaleOnlyByKnownName() {
    XCTAssertEqual(VoiceSelection.choose(from: [voice("Serena", gender: .unspecified)])?.match, .britishFemale)
    XCTAssertEqual(VoiceSelection.choose(from: [voice("Serena (Premium)", gender: .unspecified)])?.match, .britishFemale)
    XCTAssertEqual(VoiceSelection.choose(from: [voice("Oliver", gender: .unspecified)])?.match, .britishOther)
    // A stated gender isn't second-guessed by name.
    XCTAssertEqual(VoiceSelection.choose(from: [voice("Kate", gender: .male)])?.match, .britishOther)
  }

  func testNoveltyAndEloquenceVoicesDontCount() {
    let flo = voice("Flo", id: "com.apple.eloquence.en-GB.Flo")
    let albert = voice("Albert", "en-US", gender: .unspecified, id: "com.apple.speech.synthesis.voice.Albert")
    var novelty = voice("Zarvox")
    novelty.isNovelty = true
    XCTAssertEqual(VoiceSelection.choose(from: [flo, daniel])?.voice.name, "Daniel")
    XCTAssertNil(VoiceSelection.choose(from: [flo, albert, novelty]))
  }

  func testFallbackOrderWithNoBritishVoice() {
    let choice = VoiceSelection.choose(from: [samantha, voice("Tessa", "en-ZA"), voice("Rishi", "en-IN", gender: .male), voice("Moira", "en-IE")])
    XCTAssertEqual(choice?.voice.name, "Moira")
    XCTAssertEqual(choice?.match, .englishFemale)
    XCTAssertEqual(VoiceSelection.choose(from: [voice("Rishi", "en-IN", gender: .male)])?.match, .englishOther)
    XCTAssertNil(VoiceSelection.choose(from: [voice("Anna", "de-DE")]))
  }

  func testLanguageSpellingsAreTolerated() {
    XCTAssertEqual(VoiceSelection.choose(from: [voice("Serena", "en_GB")])?.match, .britishFemale)
  }

  func testDisplayString() {
    XCTAssertEqual(VoiceSelection.displayString(for: voice("Serena")), "Voice: Serena, British")
    XCTAssertEqual(VoiceSelection.displayString(for: voice("Serena (Premium)")), "Voice: Serena, British")
    XCTAssertEqual(VoiceSelection.displayString(for: voice("Karen", "en-AU")), "Voice: Karen, Australian")
  }

  func testDownloadNoticeOnlyWhenNeeded() {
    let british = VoiceChoice(voice: voice("Serena"), match: .britishFemale)
    let fallback = VoiceChoice(voice: daniel, match: .britishOther)
    XCTAssertTrue(VoiceSelection.shouldOfferDownload(choice: fallback, alreadyHeard: false, followsVoiceOver: false))
    XCTAssertTrue(VoiceSelection.shouldOfferDownload(choice: nil, alreadyHeard: false, followsVoiceOver: false))
    XCTAssertFalse(VoiceSelection.shouldOfferDownload(choice: british, alreadyHeard: false, followsVoiceOver: false))
    XCTAssertFalse(VoiceSelection.shouldOfferDownload(choice: fallback, alreadyHeard: true, followsVoiceOver: false))
    XCTAssertFalse(VoiceSelection.shouldOfferDownload(choice: fallback, alreadyHeard: false, followsVoiceOver: true))
  }
}

@MainActor
final class VoicePreferenceMigrationTests: XCTestCase {
  private var suiteName = ""
  private var defaults = UserDefaults()

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "VoicePreferenceMigrationTests.\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
  }

  override func tearDown() async throws {
    defaults.removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  func testOldStoredFalseGetsTheNewDefaultAndIsRemoved() {
    defaults.set(false, forKey: "a11y.useAppVoice")
    XCTAssertFalse(A11yPreferences(defaults: defaults).useVoiceOverVoice)
    XCTAssertNil(defaults.object(forKey: "a11y.useAppVoice"))
  }

  func testRealChoiceSurvives() {
    A11yPreferences(defaults: defaults).useVoiceOverVoice = true
    defaults.set(true, forKey: "a11y.useAppVoice")
    XCTAssertTrue(A11yPreferences(defaults: defaults).useVoiceOverVoice)
  }

  func testVoiceControlOffSwitchPersists() {
    A11yPreferences(defaults: defaults).voiceControlEnabled = false
    XCTAssertFalse(A11yPreferences(defaults: defaults).voiceControlEnabled)
  }

  func testOutputRouting() {
    typealias Output = CameraAccess.Announcer.Output
    let own = Output.ownVoice(prefersAssistiveTechnologySettings: false)
    // The default: the app's voice, VoiceOver or not, status or reply.
    XCTAssertEqual(Output.choose(kind: .status, voiceOverRunning: true, useVoiceOverVoice: false), own)
    XCTAssertEqual(Output.choose(kind: .reply, voiceOverRunning: true, useVoiceOverVoice: false), own)
    XCTAssertEqual(Output.choose(kind: .status, voiceOverRunning: false, useVoiceOverVoice: true), own)
    // Opted in, with VoiceOver running.
    XCTAssertEqual(Output.choose(kind: .status, voiceOverRunning: true, useVoiceOverVoice: true), .voiceOver)
    XCTAssertEqual(
      Output.choose(kind: .reply, voiceOverRunning: true, useVoiceOverVoice: true), .ownVoice(prefersAssistiveTechnologySettings: true))
  }
}

final class VoiceCommandParserTests: XCTestCase {
  private let camera = VoiceContext(screen: .camera)

  private func parse(_ text: String, _ context: VoiceContext? = nil) -> VoiceParseResult {
    VoiceCommandParser.parse(text, context: context ?? camera)
  }

  func testCameraCommands() {
    let expected: [(String, VoiceCommand)] = [
      ("read", .read), ("read this", .read), ("read aloud", .read), ("Read it aloud.", .read),
      ("stop", .stop), ("pause", .stop), ("quiet", .stop),
      ("repeat", .repeatLast), ("say that again", .repeatLast),
      ("status", .status), ("what's the status", .status),
      ("faster", .faster), ("slower", .slower), ("slow down", .slower),
      ("help", .help), ("what can I say", .help),
    ]
    for (text, command) in expected {
      XCTAssertEqual(parse(text), .command(command), text)
    }
  }

  func testFillerIsTolerated() {
    XCTAssertEqual(parse("please read this"), .command(.read))
    XCTAssertEqual(parse("Can you read this please"), .command(.read))
    XCTAssertEqual(parse("could you read this for me"), .command(.read))
    XCTAssertEqual(parse("um stop"), .command(.stop))
    XCTAssertEqual(parse("stop thank you"), .command(.stop))
  }

  func testConversationIsIgnoredInSilence() {
    XCTAssertEqual(parse("I'll read this book later"), .ignored(.unrecognized))
    XCTAssertEqual(parse("stop listening to him"), .ignored(.unrecognized))
    XCTAssertEqual(parse("did you take a photo of it"), .ignored(.unrecognized))
    XCTAssertEqual(parse(""), .ignored(.empty))
    XCTAssertEqual(parse("..."), .ignored(.empty))
  }

  func testWakeWordWhileSpeaking() {
    let speaking = VoiceContext(screen: .camera, isSpeaking: true, spokenText: "The bus did not stop at the corner.")
    XCTAssertEqual(parse("stop", speaking), .ignored(.needsWakeWord))
    XCTAssertEqual(parse("reader, stop", speaking), .command(.stop))
    XCTAssertEqual(parse("Hey reader stop", speaking), .command(.stop))
    XCTAssertEqual(parse("reader please stop now", speaking), .command(.stop))
  }

  func testTranscriptOverlappingTheBookIsDiscarded() {
    let speaking = VoiceContext(screen: .camera, isSpeaking: true, spokenText: "She looked up. Reader, stop the car, he said.")
    XCTAssertEqual(parse("reader stop", speaking), .ignored(.overlapsSpeech))
    XCTAssertEqual(parse("reader stop the car", speaking), .ignored(.overlapsSpeech))
    // "stopped" isn't "stop": the user really said it.
    let other = VoiceContext(screen: .camera, isSpeaking: true, spokenText: "The reader stopped and looked up.")
    XCTAssertEqual(parse("reader stop", other), .command(.stop))
  }

  func testIdleOverlapWithJustFinishedText() {
    let justSpoke = VoiceContext(screen: .camera, isSpeaking: false, spokenText: "Press stop to end.")
    XCTAssertEqual(parse("stop", justSpoke), .ignored(.overlapsSpeech))
    XCTAssertEqual(parse("read", justSpoke), .command(.read))
    // A recogniser slip in the middle still counts as hearing ourselves.
    let longer = VoiceContext(screen: .camera, spokenText: "Ready to take a photo.")
    XCTAssertEqual(parse("to take a photograph", longer), .ignored(.overlapsSpeech))
  }

  func testWakeWordNotUnderstood() {
    XCTAssertEqual(parse("reader, make me a sandwich"), .notUnderstood)
    XCTAssertEqual(parse("reader"), .notUnderstood)
  }

  func testRequiresWakeWordWhenIdle() {
    let context = VoiceContext(screen: .camera, requiresWakeWord: true)
    XCTAssertEqual(parse("read text", context), .ignored(.needsWakeWord))
    XCTAssertEqual(parse("reader read text", context), .command(.read))
  }

  func testCommandsDependOnTheScreen() {
    let welcome = VoiceContext(screen: .welcome)
    XCTAssertEqual(parse("connect", welcome), .command(.connect))
    XCTAssertEqual(parse("yes", welcome), .command(.yes))
    XCTAssertEqual(parse("try again", welcome), .command(.tryAgain))
    XCTAssertEqual(parse("continue", welcome), .command(.continueOn))
    XCTAssertEqual(parse("take a photo", welcome), .ignored(.unrecognized))
    XCTAssertEqual(parse("read", welcome), .ignored(.unavailableHere))
    XCTAssertEqual(parse("reader read", welcome), .notUnderstood)

    XCTAssertEqual(parse("yes", camera), .ignored(.unavailableHere))
    XCTAssertEqual(parse("not now", camera), .ignored(.unavailableHere))
    XCTAssertEqual(parse("try again", VoiceContext(screen: .home)), .command(.tryAgain))
    XCTAssertEqual(parse("read", VoiceContext(screen: .home)), .ignored(.unavailableHere))
    XCTAssertEqual(parse("connect", VoiceContext(screen: .home)), .command(.connect))
    // The main screen has no camera steps: reading starts the camera, and photos are gone.
    XCTAssertEqual(parse("connect", camera), .ignored(.unavailableHere))
    XCTAssertEqual(parse("take a photo", camera), .ignored(.unrecognized))

    XCTAssertEqual(parse("next", camera), .ignored(.unavailableHere))
    XCTAssertEqual(parse("next", VoiceContext(screen: .camera, hasReadSentences: true)), .command(.next))
    XCTAssertEqual(parse("carry on", VoiceContext(screen: .camera, hasReadSentences: true)), .command(.continueOn))
  }

  func testHelpListsOnlyWhatIsValidNow() {
    let cameraHelp = VoiceCommandParser.helpLine(context: camera)
    XCTAssertTrue(cameraHelp.contains("read"))
    XCTAssertFalse(cameraHelp.contains("connect"))
    XCTAssertFalse(cameraHelp.contains("not now"))
    let welcomeHelp = VoiceCommandParser.helpLine(context: VoiceContext(screen: .welcome))
    XCTAssertTrue(welcomeHelp.contains("connect"))
    XCTAssertTrue(welcomeHelp.contains("not now"))
    XCTAssertFalse(welcomeHelp.contains("read,"))
    XCTAssertTrue(VoiceCommandParser.helpLine(context: VoiceContext(screen: .home, requiresWakeWord: true)).hasPrefix("Say reader first"))
  }

  /// "Not now" ends in a word that is otherwise filler ("now"), so it has to survive stripping.
  func testNotNowAndSkipAreUnderstoodOnTheFirstScreen() {
    let welcome = VoiceContext(screen: .welcome)
    for phrase in ["not now", "not now please", "please not now", "no thanks", "skip", "skip for now", "maybe later"] {
      XCTAssertEqual(parse(phrase, welcome), .command(.no), phrase)
    }
    XCTAssertEqual(parse("please try again", welcome), .command(.tryAgain))
    XCTAssertEqual(parse("can you connect my glasses please", welcome), .command(.connect))
  }

  func testFirstScreenHasHelpStopRepeatAndBothWaysOut() {
    let available = VoiceCommandParser.availableCommands(context: VoiceContext(screen: .welcome))
    for command in [VoiceCommand.help, .stop, .repeatLast, .connect, .tryAgain, .no] {
      XCTAssertTrue(available.contains(command), command.rawValue)
    }
  }

  // MARK: New phrases

  func testEveryPhraseBelongsToOneCommand() {
    var owner: [String: VoiceCommand] = [:]
    for (command, list) in VoiceCommandParser.phrases {
      for phrase in list {
        XCTAssertNil(owner[phrase], "\"\(phrase)\" is both \(owner[phrase]?.rawValue ?? "") and \(command.rawValue)")
        owner[phrase] = command
      }
    }
    for command in VoiceCommand.allCases {
      XCTAssertFalse(VoiceCommandParser.phrases[command, default: []].isEmpty, "\(command.rawValue) has no phrases")
    }
  }

  func testReadingPhrases() {
    let reading = VoiceContext(screen: .camera, hasReadSentences: true)
    let expected: [(String, VoiceCommand)] = [
      ("resume", .resume), ("keep reading", .resume), ("carry on reading", .resume), ("play", .resume),
      ("continue reading", .resume), ("please keep reading", .resume),
      ("continue", .continueOn), ("go on", .continueOn), ("carry on", .continueOn),
      ("next", .next), ("next sentence", .next), ("back", .back),
    ]
    for (text, command) in expected {
      XCTAssertEqual(parse(text, reading), .command(command), text)
    }
    // Nothing read yet: nothing to resume.
    XCTAssertEqual(parse("resume", camera), .ignored(.unavailableHere))
    XCTAssertEqual(parse("play", camera), .ignored(.unavailableHere))
  }

  /// Goodbye stops listening, so a bystander's "bye" mustn't: it needs the wake word.
  func testGoodbyeEverywhereWithTheWakeWord() {
    for screen in [VoiceScreen.welcome, .home, .camera] {
      for phrase in ["goodbye", "good bye", "bye", "I'm done", "I am done", "stop listening", "goodbye thanks", "go to sleep"] {
        let context = VoiceContext(screen: screen)
        XCTAssertEqual(parse("reader, \(phrase)", context), .command(.goodbye), "\(phrase) on \(screen)")
        XCTAssertEqual(parse(phrase, context), .ignored(.needsWakeWord), "bare \(phrase) on \(screen)")
      }
    }
    XCTAssertEqual(parse("speakup, I'm done"), .command(.goodbye))
    // Still conversation when it's part of something longer.
    XCTAssertEqual(parse("stop listening to him"), .ignored(.unrecognized))
    XCTAssertEqual(parse("I'm done with the dishes"), .ignored(.unrecognized))
  }

  func testUpdateOnlyWhileAnUpdateIsWaiting() {
    let waiting = VoiceContext(screen: .camera, canUpdate: true)
    for phrase in ["update", "update glasses", "update firmware", "update my glasses"] {
      XCTAssertEqual(parse(phrase, waiting), .command(.update), phrase)
    }
    XCTAssertEqual(parse("update", camera), .ignored(.unavailableHere))
    XCTAssertEqual(parse("update", VoiceContext(screen: .home)), .ignored(.unavailableHere))
  }

  func testSpokenSettingsOnHomeAndCamera() {
    let expected: [(String, VoiceCommand)] = [
      ("natural voice on", .naturalVoiceOn), ("use the natural voice", .naturalVoiceOn), ("turn on natural voice", .naturalVoiceOn),
      ("natural voice off", .naturalVoiceOff), ("phone voice", .naturalVoiceOff), ("use the phone voice", .naturalVoiceOff),
      ("tips on", .tipsOn), ("turn tips on", .tipsOn), ("tips off", .tipsOff), ("turn off spoken tips", .tipsOff),
      ("shorter", .shorter), ("less detail", .shorter), ("more detail", .moreDetail), ("more details", .moreDetail),
      ("listen through glasses", .glassesMic), ("listen through my glasses", .glassesMic),
      ("replay setup", .replaySetup), ("set up again", .replaySetup),
      ("disconnect", .disconnect), ("disconnect my glasses", .disconnect), ("settings", .settings),
    ]
    for screen in [VoiceScreen.home, .camera] {
      for (text, command) in expected {
        XCTAssertEqual(parse(text, VoiceContext(screen: screen)), .command(command), "\(text) on \(screen)")
      }
    }
    // Not on the first screen: setup is what's happening there.
    XCTAssertEqual(parse("shorter", VoiceContext(screen: .welcome)), .ignored(.unavailableHere))
    XCTAssertEqual(parse("disconnect", VoiceContext(screen: .welcome)), .ignored(.unavailableHere))
  }

  func testOKAndYesWords() {
    let notice = VoiceContext(screen: .camera, extraCommands: [.ok])
    for phrase in ["ok", "OK.", "okay", "got it", "dismiss", "ok thanks"] {
      XCTAssertEqual(parse(phrase, notice), .command(.ok), phrase)
    }
    XCTAssertEqual(parse("ok", camera), .ignored(.unavailableHere))
    let question = VoiceContext(screen: .camera, promptCommands: [.yes, .no])
    for phrase in ["yes", "yeah", "yep", "allow", "allow it"] {
      XCTAssertEqual(parse(phrase, question), .command(.yes), phrase)
    }
    // Loose yeses can open Meta AI or disconnect: wake word only.
    for phrase in ["sure", "go ahead"] {
      XCTAssertEqual(parse(phrase, question), .ignored(.needsWakeWord), phrase)
      XCTAssertEqual(parse("reader, \(phrase)", question), .command(.yes), phrase)
    }
    for phrase in ["no", "not now", "cancel"] {
      XCTAssertEqual(parse(phrase, question), .command(.no), phrase)
    }
    // "cancel" on the first screen would skip setup: bare only inside an alert.
    let welcome = VoiceContext(screen: .welcome)
    XCTAssertEqual(parse("cancel", welcome), .ignored(.needsWakeWord))
    XCTAssertEqual(parse("reader cancel", welcome), .command(.no))
    // "ok" is still a wake word lead-in.
    XCTAssertEqual(parse("ok reader stop", camera), .command(.stop))
  }

  func testABlockingPromptHidesTheScreensCommands() {
    let sheet = VoiceContext(screen: .welcome, promptCommands: [.yes, .continueOn, .connect, .no])
    XCTAssertEqual(parse("yes", sheet), .command(.yes))
    XCTAssertEqual(parse("not now", sheet), .command(.no))
    XCTAssertEqual(parse("try again", sheet), .ignored(.unavailableHere))
    XCTAssertEqual(parse("help", sheet), .command(.help))
    XCTAssertEqual(parse("reader, goodbye", sheet), .command(.goodbye))
    let alert = VoiceContext(screen: .camera, promptCommands: CameraProblem.voiceCommands(for: .tryAgain))
    for (phrase, command) in [("try again", VoiceCommand.tryAgain), ("yes", .yes), ("ok", .ok), ("no", .no), ("read", .read)] {
      XCTAssertEqual(parse(phrase, alert), .command(command), phrase)
    }
    XCTAssertEqual(parse("status", alert), .ignored(.unavailableHere))
    XCTAssertEqual(parse("shorter", alert), .ignored(.unavailableHere))
  }

  /// "SpeakUp" is a wake word, however the recogniser writes it. "speak up" alone isn't "faster".
  func testSpeakUpIsAWakeWord() {
    XCTAssertEqual(parse("speak up read"), .command(.read))
    XCTAssertEqual(parse("SpeakUp, read this"), .command(.read))
    XCTAssertEqual(parse("Speak-Up status"), .command(.status))
    XCTAssertEqual(parse("hey speak up help"), .command(.help))
    XCTAssertEqual(parse("speak up"), .notUnderstood)
    XCTAssertEqual(parse("speakup"), .notUnderstood)
    XCTAssertEqual(parse("speak up please"), .notUnderstood)
    XCTAssertEqual(parse("speak up faster"), .command(.faster), "the wake word, then faster")
    let speaking = VoiceContext(screen: .camera, isSpeaking: true, spokenText: "The bus was late.")
    XCTAssertEqual(parse("speak up stop", speaking), .command(.stop))
    XCTAssertEqual(parse("speakup, stop", speaking), .command(.stop))
    XCTAssertEqual(parse("speak", speaking), .ignored(.needsWakeWord))
  }

  /// A question ends "Say yes or no.", so for a second or so a bare "yes" would match the echo
  /// check. Once the question has finished, its own answers are the user.
  func testAPromptAnswerAfterTheQuestionIsNotAnEcho() {
    let asked = VoiceContext(screen: .camera, spokenText: "Disconnect your glasses? Say yes or no.", promptCommands: [.yes, .no])
    XCTAssertEqual(parse("yes", asked), .command(.yes))
    XCTAssertEqual(parse("no", asked), .command(.no))
    let offer = VoiceContext(
      screen: .camera, spokenText: "Want me to listen through your glasses? Say yes or no.", extraCommands: [.yes, .no])
    XCTAssertEqual(parse("yes", offer), .command(.yes))
    // Still speaking: the wake word rule applies.
    var speaking = asked
    speaking.isSpeaking = true
    XCTAssertEqual(parse("yes", speaking), .ignored(.needsWakeWord))
    // Not an answer to anything: the echo check still drops what we just said.
    let welcome = VoiceContext(screen: .welcome, spokenText: "Say yes to connect.")
    XCTAssertEqual(parse("yes", welcome), .ignored(.overlapsSpeech))
  }

  func testHelpLeavesTheSettingsToSettings() {
    let home = VoiceContext(screen: .home)
    let help = VoiceCommandParser.helpLine(context: home)
    XCTAssertTrue(help.contains("settings"))
    XCTAssertTrue(help.contains("goodbye"))
    XCTAssertFalse(help.contains("natural voice"))
    XCTAssertFalse(help.contains("disconnect"))
    let settings = VoiceCommandParser.settingsLine(context: home)
    for phrase in ["natural voice on", "phone voice", "tips on", "tips off", "shorter", "more detail", "listen through glasses", "replay setup", "disconnect"] {
      XCTAssertTrue(settings.contains(phrase), phrase)
    }
  }
}

final class VoiceListenerRuleTests: XCTestCase {
  private let allowed = VoiceListenerPolicy.Inputs(phoneMic: .granted, speechRecognition: .granted)

  func testPhoneIsUsedWithNoSession() {
    XCTAssertEqual(VoiceListenerPolicy.decide(allowed), .phone)
  }

  func testGlassesPreferredWhenSessionAndMicGranted() {
    var inputs = allowed
    inputs.glassesAvailable = true
    XCTAssertEqual(VoiceListenerPolicy.decide(inputs), .phone, "no wearable mic grant yet")
    inputs.glassesMicGranted = true
    XCTAssertEqual(VoiceListenerPolicy.decide(inputs), .glasses)
    inputs.glassesCoolingOff = true
    XCTAssertEqual(VoiceListenerPolicy.decide(inputs), .phone, "falls back after a failure")
  }

  func testGlassesWorkWithPhonePermissionsDenied() {
    var inputs = VoiceListenerPolicy.Inputs(glassesAvailable: true, glassesMicGranted: true, phoneMic: .denied, speechRecognition: .denied)
    XCTAssertEqual(VoiceListenerPolicy.decide(inputs), .glasses)
    inputs.glassesAvailable = false
    XCTAssertEqual(VoiceListenerPolicy.decide(inputs), .denied)
  }

  func testPausesAndOffWin() {
    var inputs = allowed
    inputs.inBackground = true
    XCTAssertEqual(VoiceListenerPolicy.decide(inputs), .paused(.background))
    inputs = allowed
    inputs.interrupted = true
    XCTAssertEqual(VoiceListenerPolicy.decide(inputs), .paused(.interrupted))
    inputs.enabled = false
    XCTAssertEqual(VoiceListenerPolicy.decide(inputs), .off)
  }

  func testPermissionsAndRecognizer() {
    XCTAssertEqual(VoiceListenerPolicy.decide(.init()), .needsPermission)
    XCTAssertEqual(VoiceListenerPolicy.decide(.init(phoneMic: .granted, speechRecognition: .notDetermined)), .needsPermission)
    XCTAssertEqual(VoiceListenerPolicy.decide(.init(phoneMic: .denied, speechRecognition: .notDetermined)), .denied)
    XCTAssertEqual(
      VoiceListenerPolicy.decide(.init(phoneMic: .granted, speechRecognition: .granted, onDeviceRecognizerAvailable: false)),
      .noOnDeviceRecognition)
  }

  func testLocaleChoice() {
    XCTAssertEqual(PhoneLocaleChoice.choose(deviceLocale: "en_ZA") { _ in true }, "en-ZA")
    XCTAssertEqual(PhoneLocaleChoice.choose(deviceLocale: "en_ZA") { $0 != "en-ZA" }, "en-GB")
    XCTAssertEqual(PhoneLocaleChoice.choose(deviceLocale: "en_ZA") { $0 == "en-US" }, "en-US")
    XCTAssertNil(PhoneLocaleChoice.choose(deviceLocale: "en_ZA") { _ in false })
    XCTAssertEqual(PhoneLocaleChoice.candidates(deviceLocale: "en_ZA@rg=gbzzzz"), ["en-ZA", "en-GB", "en-US"])
    XCTAssertEqual(PhoneLocaleChoice.candidates(deviceLocale: "en_GB"), ["en-GB", "en-US"])
    // The commands are English, so a German phone listens in English.
    XCTAssertEqual(PhoneLocaleChoice.candidates(deviceLocale: "de_DE"), ["en-GB", "en-US"])
  }

  func testBackoffDoublesCapsAndResets() {
    var backoff = RestartBackoff()
    XCTAssertEqual((0..<8).map { _ in backoff.next() }, [0.5, 1, 2, 4, 8, 16, 30, 30])
    backoff.noteRanFor(5)
    XCTAssertEqual(backoff.attempts, 8)
    backoff.noteRanFor(RestartBackoff.stableAfter)
    XCTAssertEqual(backoff.next(), 0.5)
  }

  func testRoutineRecognitionErrors() {
    XCTAssertEqual(SpeechRecognitionFailure.classify(domain: "kAFAssistantErrorDomain", code: 1110), .routine)
    XCTAssertEqual(SpeechRecognitionFailure.classify(domain: "kLSRErrorDomain", code: 301), .routine)
    XCTAssertEqual(SpeechRecognitionFailure.classify(domain: "kLSRErrorDomain", code: 201), .recognizerUnavailable)
    XCTAssertEqual(SpeechRecognitionFailure.classify(domain: "kLSRErrorDomain", code: 300), .transient)
    XCTAssertEqual(SpeechRecognitionFailure.classify(domain: "kAFAssistantErrorDomain", code: 1101), .transient)
    XCTAssertEqual(SpeechRecognitionFailure.classify(domain: "other", code: 1110), .transient)
  }

  func testGlassesTranscriptFilter() {
    XCTAssertNil(GlassesTranscriptFilter.accepted(text: "stop", isFinal: false, confidence: 1))
    XCTAssertEqual(GlassesTranscriptFilter.accepted(text: "stop", isFinal: true, confidence: 0.9), "stop")
    XCTAssertEqual(GlassesTranscriptFilter.accepted(text: "stop", isFinal: true, confidence: -1), "stop", "-1 is no score")
    XCTAssertNil(GlassesTranscriptFilter.accepted(text: "stop", isFinal: true, confidence: 0.1))
    XCTAssertNil(GlassesTranscriptFilter.accepted(text: "", isFinal: true, confidence: -1))
  }

  func testGlassesSpeechFlag() throws {
    let suite = "VoiceFlag.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertTrue(VoiceFeatureFlags.glassesSpeechEnabled(defaults: defaults, isDebugBuild: true))
    XCTAssertFalse(VoiceFeatureFlags.glassesSpeechEnabled(defaults: defaults, isDebugBuild: false))
    defaults.set(true, forKey: VoiceFeatureFlags.glassesSpeechKey)
    XCTAssertTrue(VoiceFeatureFlags.glassesSpeechEnabled(defaults: defaults, isDebugBuild: false))
  }

  func testCommandsNeverOpenHFP() {
    for ducking in [false, true] {
      let listening = A11yAudioSession.sessionConfiguration(phoneMic: true, ducking: ducking)
      XCTAssertEqual(listening.category, .playAndRecord)
      XCTAssertTrue(listening.options.contains(.allowBluetoothA2DP))
      XCTAssertTrue(listening.options.contains(.defaultToSpeaker))
      XCTAssertFalse(listening.options.contains(.allowBluetoothHFP))
      XCTAssertEqual(listening.options.contains(.duckOthers), ducking)
      XCTAssertEqual(listening.options.contains(.mixWithOthers), !ducking)
    }
    // Without the phone mic, it's what it always was.
    let idle = A11yAudioSession.sessionConfiguration(phoneMic: false, ducking: false)
    XCTAssertEqual(idle.category, .playback)
    XCTAssertEqual(idle.mode, .spokenAudio)
    XCTAssertEqual(idle.options, .mixWithOthers)
    XCTAssertEqual(A11yAudioSession.sessionConfiguration(phoneMic: false, ducking: true).options, .duckOthers)
  }
}

// MARK: - VoiceControl with fakes

@MainActor
private final class FakeListener: SpeechListener {
  let kind: VoiceListenerKind
  var onEvent: (@MainActor (SpeechListenerEvent) -> Void)?
  var starts = 0
  var stops = 0

  init(kind: VoiceListenerKind) { self.kind = kind }

  func start() { starts += 1 }
  func stop() { stops += 1 }
}

@MainActor
private final class Harness {
  var earcons: [Earcon] = []
  var lines: [String] = []
  var finishLines = true
  var speaking = false
  var spokenText = ""
  var micHearsVoiceOver = false
  var phoneMic = VoicePermission.granted
  var speech = VoicePermission.granted
  var locale: String? = "en-ZA"
  /// Microphone dialogs shown; speech recognition dialogs in `speechRequested`.
  var requested = 0
  var speechRequested = 0
  var grantOnRequest = true
  var hasCloudKey = true
  var cloudKeyRefused = false
  var phoneListeners: [FakeListener] = []
  var stopSpeechCalls = 0
  var repeatCalls = 0
  var idleTimerDisabled = false
  var now = Date(timeIntervalSince1970: 1000)

  func environment() -> VoiceControl.Environment {
    VoiceControl.Environment(
      isInert: false,
      makePhoneListener: { [unowned self] _ in
        let listener = FakeListener(kind: .phone)
        phoneListeners.append(listener)
        return listener
      },
      phoneLocale: { [unowned self] in locale },
      phoneMicPermission: { [unowned self] in phoneMic },
      speechPermission: { [unowned self] in speech },
      requestMicPermission: { [unowned self] in
        requested += 1
        phoneMic = grantOnRequest ? .granted : .denied
      },
      requestSpeechPermission: { [unowned self] in
        speechRequested += 1
        speech = grantOnRequest ? .granted : .denied
      },
      say: { [unowned self] text, earcon, _, onFinish in
        lines.append(text)
        if let earcon { earcons.append(earcon) }
        onFinish?(finishLines)
      },
      playEarcon: { [unowned self] in earcons.append($0) },
      isSpeaking: { [unowned self] in speaking },
      textBeingSpoken: { [unowned self] in spokenText },
      stopSpeech: { [unowned self] in stopSpeechCalls += 1 },
      repeatLast: { [unowned self] in repeatCalls += 1 },
      hasReadSentences: { false },
      isReading: { false },
      micHearsVoiceOver: { [unowned self] _ in micHearsVoiceOver },
      followsVoiceOverRate: { false },
      setIdleTimerDisabled: { [unowned self] in idleTimerDisabled = $0 },
      glassesSpeechEnabled: { true },
      hasCloudKey: { [unowned self] in hasCloudKey },
      cloudKeyRefused: { [unowned self] in cloudKeyRefused },
      now: { [unowned self] in now })
  }
}

@MainActor
final class VoiceControlTests: XCTestCase {
  private var suiteName = ""
  private var defaults = UserDefaults()
  private var preferences: A11yPreferences!
  private var harness: Harness!
  private var control: VoiceControl!

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "VoiceControlTests.\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    preferences = A11yPreferences(defaults: defaults)
    harness = Harness()
    control = VoiceControl(environment: harness.environment(), preferences: preferences)
  }

  override func tearDown() async throws {
    defaults.removePersistentDomain(forName: suiteName)
    control = nil
    harness = nil
    try await super.tearDown()
  }

  private func settle() async {
    for _ in 0..<5 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(20))
  }

  private func beginListening() -> FakeListener {
    control.begin()
    control.setScreen(.camera) { _ in false }
    let listener = harness.phoneListeners.last!
    listener.onEvent?(.started)
    return listener
  }

  func testStartsListeningOnLaunchWithPermissions() {
    let listener = beginListening()
    XCTAssertEqual(listener.starts, 1)
    XCTAssertEqual(control.status, .listening)
    XCTAssertEqual(control.activeListener, .phone)
    XCTAssertTrue(harness.idleTimerDisabled)
  }

  func testFirstListenCueAndIntroLineOnlyOnce() {
    _ = beginListening()
    XCTAssertEqual(harness.earcons, [.listening])
    XCTAssertEqual(harness.lines, [SpokenMessage.voiceControlOn])
    XCTAssertTrue(preferences.voiceControlIntroHeard)

    let again = VoiceControl(environment: harness.environment(), preferences: preferences)
    harness.lines = []
    again.begin()
    again.setScreen(.camera) { _ in false }
    harness.phoneListeners.last?.onEvent?(.started)
    XCTAssertEqual(harness.lines, [])
  }

  func testIntroComesBackIfCutOff() {
    harness.finishLines = false
    _ = beginListening()
    XCTAssertFalse(preferences.voiceControlIntroHeard)
  }

  func testOffSwitch() {
    let listener = beginListening()
    control.setEnabled(false)
    XCTAssertEqual(control.status, .off)
    XCTAssertEqual(listener.stops, 1)
    XCTAssertFalse(preferences.voiceControlEnabled)
    XCTAssertFalse(harness.idleTimerDisabled)
  }

  func testEarconComesBeforeTheActionAndCommandIsRemembered() {
    _ = beginListening()
    harness.earcons = []
    var earconsAtAction: [Earcon] = []
    control.setScreen(.camera) { [harness] _ in
      earconsAtAction = harness!.earcons
      return true
    }
    control.inject(transcript: "read this")
    XCTAssertEqual(earconsAtAction, [.heard])
    XCTAssertEqual(control.lastCommand, .read)
  }

  func testConversationGetsNoReaction() {
    _ = beginListening()
    harness.earcons = []
    harness.lines = []
    control.inject(transcript: "what time is the bus")
    XCTAssertEqual(harness.earcons, [])
    XCTAssertEqual(harness.lines, [])
    XCTAssertNil(control.lastCommand)
  }

  func testWakeWordNotUnderstoodSaysSoBriefly() {
    _ = beginListening()
    harness.earcons = []
    harness.lines = []
    control.inject(transcript: "reader do a backflip")
    XCTAssertEqual(harness.earcons, [.uncertain])
    XCTAssertEqual(harness.lines, [SpokenMessage.voiceNotUnderstood])
  }

  func testWhileSpeakingOnlyTheWakeWordCounts() {
    _ = beginListening()
    harness.speaking = true
    harness.spokenText = "The train did not stop."
    control.inject(transcript: "stop")
    XCTAssertEqual(harness.stopSpeechCalls, 0)
    control.inject(transcript: "reader stop")
    XCTAssertEqual(harness.stopSpeechCalls, 1)
  }

  func testHelpSpeaksWhatIsValidHere() {
    _ = beginListening()
    harness.lines = []
    control.inject(transcript: "help")
    XCTAssertEqual(harness.lines.count, 1)
    XCTAssertTrue(harness.lines[0].contains("read"))
    XCTAssertEqual(control.availableCommands.contains(.read), true)
  }

  func testFasterAndSlowerChangeTheRateWithinLimits() {
    _ = beginListening()
    let start = preferences.speechRate
    control.inject(transcript: "faster")
    XCTAssertGreaterThan(preferences.speechRate, start)
    preferences.speechRate = AVSpeechUtteranceMaximumSpeechRate
    harness.lines = []
    control.inject(transcript: "faster")
    XCTAssertEqual(harness.lines, [SpokenMessage.voiceFastest])
  }

  func testInterruptionPausesAndResumes() {
    let listener = beginListening()
    control.noteInterruption(began: true)
    XCTAssertEqual(listener.stops, 1)
    XCTAssertEqual(control.status, .paused)
    control.noteInterruption(began: false)
    XCTAssertEqual(harness.phoneListeners.count, 2)
    XCTAssertEqual(control.status, .starting)
  }

  func testBackgroundStopsTheMic() {
    let listener = beginListening()
    control.noteBackground(true)
    XCTAssertEqual(listener.stops, 1)
    XCTAssertEqual(control.reason, VoicePauseReason.background.text)
    XCTAssertFalse(harness.idleTimerDisabled)
    control.noteBackground(false)
    XCTAssertEqual(harness.phoneListeners.count, 2)
  }

  func testFailureRestartsWithoutACueOrALine() async throws {
    let listener = beginListening()
    harness.earcons = []
    harness.lines = []
    listener.onEvent?(.failed(reason: "test", transient: true))
    XCTAssertEqual(listener.stops, 1)
    XCTAssertEqual(control.status, .starting)
    try await Task.sleep(for: .milliseconds(700))  // first backoff is 0.5 s
    XCTAssertEqual(harness.phoneListeners.count, 2)
    harness.phoneListeners.last?.onEvent?(.started)
    XCTAssertEqual(control.status, .listening)
    XCTAssertEqual(harness.earcons, [])
    XCTAssertEqual(harness.lines, [])
  }

  func testRepeatedFailureIsSpokenOnce() async throws {
    _ = beginListening()
    harness.lines = []
    for _ in 0..<3 {
      let current = harness.phoneListeners.last!
      current.onEvent?(.failed(reason: "test", transient: true))
      if control.status == .unavailable { break }
      try await Task.sleep(for: .seconds(control.status == .starting ? 2.2 : 0))
    }
    XCTAssertEqual(control.status, .unavailable)
    XCTAssertEqual(harness.lines, [SpokenMessage.voiceControlTroubled])
  }

  func testAFlappingListenerSpeaksTroubleOnlyOnce() async throws {
    _ = beginListening()
    harness.lines = []
    // Starts then fails at once, again and again; time doesn't pass, so it never counts as stable.
    for _ in 0..<4 {
      harness.phoneListeners.last?.onEvent?(.failed(reason: "test", transient: true))
      control.noteBackground(false)  // skips the backoff wait: reconcile starts a new listener
      harness.phoneListeners.last?.onEvent?(.started)
    }
    XCTAssertEqual(harness.lines.filter { $0 == SpokenMessage.voiceControlTroubled }.count, 1)
  }

  func testDeniedSpeaksWhyAndHowOncePerLaunch() {
    harness.phoneMic = .denied
    control.begin()
    control.setScreen(.camera) { _ in false }
    XCTAssertEqual(control.status, .unavailable)
    XCTAssertEqual(control.reason, SpokenMessage.voicePermissionDenied)
    XCTAssertEqual(harness.lines, [SpokenMessage.voicePermissionDenied])
    XCTAssertEqual(harness.requested, 0)
    control.setScreen(.home) { _ in false }
    XCTAssertEqual(harness.lines.count, 1)
    XCTAssertEqual(harness.phoneListeners.count, 0)
  }

  func testNoOnDeviceRecognizerSaysWhy() {
    harness.locale = nil
    control.begin()
    control.setScreen(.camera) { _ in false }
    XCTAssertEqual(control.status, .unavailable)
    XCTAssertEqual(harness.lines, [SpokenMessage.voiceNoOnDeviceRecognition])
  }

  /// The first screen is where "say connect" is first offered, so it explains and asks there too.
  func testFirstScreenExplainsThenAsks() async {
    harness.phoneMic = .notDetermined
    harness.speech = .notDetermined
    control.begin()
    control.setScreen(.welcome) { _ in false }
    await settle()
    XCTAssertEqual(harness.lines.first, SpokenMessage.voiceControlExplanation)
    XCTAssertEqual(harness.requested, 1)
  }

  func testMainScreenExplainsThenAsksThenListens() async {
    harness.phoneMic = .notDetermined
    harness.speech = .notDetermined
    control.begin()
    control.setScreen(.camera) { _ in false }
    await settle()
    XCTAssertEqual(harness.lines.first, SpokenMessage.voiceControlExplanation)
    XCTAssertEqual(harness.requested, 1)
    XCTAssertEqual(harness.phoneListeners.count, 1)
    XCTAssertEqual(harness.phoneListeners[0].starts, 1)
  }

  func testRefusedPromptSpeaksTheFixAndKeepsListeningOff() async {
    harness.phoneMic = .notDetermined
    harness.speech = .notDetermined
    harness.grantOnRequest = false
    control.begin()
    control.setScreen(.camera) { _ in false }
    await settle()
    // One dialog line before the microphone dialog; refused, so no speech dialog follows.
    XCTAssertEqual(
      harness.lines, [SpokenMessage.voiceControlExplanation, SpokenMessage.voiceDialogOnScreen, SpokenMessage.voicePermissionDenied])
    XCTAssertEqual(harness.speechRequested, 0)
    XCTAssertEqual(harness.phoneListeners.count, 0)
  }

  func testOneSpokenLineBeforeEachSystemDialog() async {
    harness.phoneMic = .notDetermined
    harness.speech = .notDetermined
    control.begin()
    control.setScreen(.welcome) { _ in false }
    await settle()
    XCTAssertEqual(
      Array(harness.lines.prefix(3)),
      [SpokenMessage.voiceControlExplanation, SpokenMessage.voiceDialogOnScreen, SpokenMessage.voiceDialogOnScreen])
    XCTAssertEqual(harness.requested, 1)
    XCTAssertEqual(harness.speechRequested, 1)
  }

  /// The first screen's "Say connect" waits until the dialogs are answered.
  func testSayConnectWaitsForThePermissionDialogs() async {
    harness.phoneMic = .notDetermined
    harness.speech = .notDetermined
    var connectOffered = false
    control.begin()
    control.setScreen(.welcome) { _ in false }
    control.whenPermissionsSettled { connectOffered = true }
    XCTAssertFalse(connectOffered)
    await settle()
    XCTAssertTrue(connectOffered, "after the dialogs")
    XCTAssertEqual(harness.requested, 1)

    // Already answered: at once.
    var again = false
    control.whenPermissionsSettled { again = true }
    XCTAssertTrue(again)
  }

  // MARK: Choosing and swapping listeners

  private func attachFakeGlasses(permission: VoicePermission = .granted) -> () -> FakeListener? {
    var made: FakeListener?
    control.attachGlasses(
      makeListener: {
        let listener = FakeListener(kind: .glasses)
        made = listener
        return listener
      },
      checkPermission: { permission },
      requestPermission: { .granted })
    return { made }
  }

  func testGlassesTakeOverWithASessionAndHandBackWhenItEnds() async {
    let phone = beginListening()
    let glasses = attachFakeGlasses()
    await settle()
    XCTAssertEqual(phone.stops, 1, "the phone mic is released")
    XCTAssertEqual(control.activeListener, .glasses)
    XCTAssertEqual(glasses()?.starts, 1)
    glasses()?.onEvent?(.started)
    XCTAssertEqual(control.status, .listening)

    control.detachGlasses()
    XCTAssertEqual(glasses()?.stops, 1)
    XCTAssertEqual(control.activeListener, .phone)
    XCTAssertEqual(harness.phoneListeners.count, 2)
  }

  func testWithoutTheWearableMicThePhoneStaysAndAButtonIsOffered() async {
    let phone = beginListening()
    _ = attachFakeGlasses(permission: .notDetermined)
    await settle()
    XCTAssertEqual(phone.stops, 0)
    XCTAssertEqual(control.activeListener, .phone)
    XCTAssertTrue(control.canRequestGlassesMicrophone)
  }

  func testGlassesFailureFallsBackToThePhone() async {
    _ = beginListening()
    let glasses = attachFakeGlasses()
    await settle()
    glasses()?.onEvent?(.started)
    glasses()?.onEvent?(.failed(reason: "startFailed", transient: false))
    XCTAssertEqual(control.activeListener, .phone)
    XCTAssertEqual(harness.phoneListeners.count, 2)
  }

  func testTranscriptsFromAReplacedListenerAreIgnored() async {
    let phone = beginListening()
    let onEvent = phone.onEvent
    _ = attachFakeGlasses()
    await settle()
    onEvent?(.transcript("read"))
    XCTAssertNil(control.lastCommand)
  }

  func testSharedInstanceIsInertInTests() {
    XCTAssertTrue(LaunchOptions.isAutomatedTest)
    VoiceControl.shared.begin()
    XCTAssertNil(VoiceControl.shared.activeListener)
    XCTAssertNotEqual(VoiceControl.shared.status, .listening)
    XCTAssertEqual(AVAudioSession.sharedInstance().category == .record, false)
  }

  // MARK: Prompts

  /// The Meta AI sheet over the first screen: "yes" answers the sheet and never reaches the screen
  /// (which would start a second connection).
  func testABlockingPromptTakesCommandsAndTheScreenGetsNone() {
    _ = beginListening()
    var screenGot: [VoiceCommand] = []
    var promptGot: [VoiceCommand] = []
    control.setScreen(.welcome) { screenGot.append($0); return true }
    control.showPrompt(.registrationRequest, accepts: [.yes, .continueOn, .connect, .no]) { promptGot.append($0); return true }
    control.inject(transcript: "yes")
    control.inject(transcript: "connect")
    control.inject(transcript: "try again")  // the screen's, not the sheet's: ignored
    XCTAssertEqual(promptGot, [.yes, .connect])
    XCTAssertEqual(screenGot, [])
    XCTAssertEqual(control.activePrompt, .registrationRequest)

    control.dismissPrompt(.registrationRequest)
    XCTAssertNil(control.activePrompt)
    control.inject(transcript: "try again")
    XCTAssertEqual(screenGot, [.tryAgain])
  }

  func testAPromptCanPassAnAnswerOnToTheScreen() {
    _ = beginListening()
    var screenGot: [VoiceCommand] = []
    control.setScreen(.welcome) { screenGot.append($0); return true }
    control.showPrompt(.wearablesError, accepts: [.yes, .tryAgain, .ok, .no]) { $0 != .no }
    control.inject(transcript: "not now")
    control.inject(transcript: "yes")
    XCTAssertEqual(screenGot, [.no])
  }

  func testRepeatAndHelpStillWorkUnderAPrompt() {
    _ = beginListening()
    control.showPrompt(.cameraPermission, accepts: [.yes, .no]) { _ in true }
    harness.lines = []
    control.inject(transcript: "repeat")
    XCTAssertEqual(harness.repeatCalls, 1)
    control.inject(transcript: "help")
    XCTAssertEqual(harness.lines.last, "You can say: yes, not now, stop, repeat, faster, slower, goodbye.")
  }

  func testANonBlockingPromptOnlyAddsItsAnswers() {
    _ = beginListening()
    var screenGot: [VoiceCommand] = []
    var dismissed = false
    control.setScreen(.camera) { screenGot.append($0); return true }
    control.showPrompt(.voiceDownload, accepts: [.ok], blocking: false) { _ in dismissed = true; return true }
    XCTAssertNil(control.activePrompt)
    control.inject(transcript: "read")
    control.inject(transcript: "got it")
    XCTAssertEqual(screenGot, [.read])
    XCTAssertTrue(dismissed)
  }

  func testConfirmAsksThenActsOnYesOrNo() {
    _ = beginListening()
    var answers: [String] = []
    harness.lines = []
    control.confirm(SpokenMessage.disconnectConfirm, onYes: { answers.append("yes") }, onNo: { answers.append("no") })
    XCTAssertEqual(harness.lines, [SpokenMessage.disconnectConfirm])
    XCTAssertEqual(control.activePrompt, .confirm)
    control.inject(transcript: "read")  // not an answer
    XCTAssertEqual(answers, [])
    control.inject(transcript: "yes")
    XCTAssertEqual(answers, ["yes"])
    XCTAssertNil(control.activePrompt)

    control.confirm(SpokenMessage.disconnectConfirm, onYes: { answers.append("yes") }, onNo: { answers.append("no") })
    control.inject(transcript: "no")
    XCTAssertEqual(answers, ["yes", "no"])
  }

  // MARK: Goodbye

  func testGoodbyeStopsListeningLetsTheScreenSleepAndSaysHowToComeBack() {
    let listener = beginListening()
    var screenGot: [VoiceCommand] = []
    control.setScreen(.camera) { screenGot.append($0); return false }
    harness.lines = []
    control.inject(transcript: "reader, goodbye")
    XCTAssertEqual(screenGot, [.goodbye], "the screen stops reading and ends the camera")
    XCTAssertEqual(harness.lines, [SpokenMessage.voiceGoodbye])
    XCTAssertTrue(SpokenMessage.voiceGoodbye.contains("SpeakUp read"), "ReadIntent's Siri phrase")
    XCTAssertEqual(listener.stops, 1)
    XCTAssertTrue(control.isAsleep)
    XCTAssertEqual(control.status, .paused)
    XCTAssertEqual(control.reason, SpokenMessage.voiceAsleep)
    XCTAssertFalse(harness.idleTimerDisabled)
    XCTAssertTrue(preferences.voiceControlEnabled, "goodbye isn't the off switch")

    control.wake()
    XCTAssertFalse(control.isAsleep)
    XCTAssertEqual(harness.phoneListeners.count, 2)
    XCTAssertTrue(harness.idleTimerDisabled)
  }

  func testComingBackToTheFrontWakesAfterGoodbye() {
    _ = beginListening()
    control.inject(transcript: "reader, I'm done")
    control.noteBackground(true)
    control.noteBackground(false)
    XCTAssertFalse(control.isAsleep)
    XCTAssertEqual(harness.phoneListeners.count, 2)
  }

  // MARK: Spoken settings

  func testSpokenSettingsChangeAndSayTheNewState() {
    _ = beginListening()
    harness.lines = []
    control.inject(transcript: "shorter")
    XCTAssertEqual(preferences.verbosity, .short)
    control.inject(transcript: "shorter")
    XCTAssertEqual(preferences.verbosity, .short)
    control.inject(transcript: "more detail")
    control.inject(transcript: "more detail")
    control.inject(transcript: "more detail")
    XCTAssertEqual(preferences.verbosity, .detailed)
    XCTAssertEqual(
      harness.lines,
      [
        SpokenMessage.verbosity(.short), SpokenMessage.verbosityShortest, SpokenMessage.verbosity(.normal),
        SpokenMessage.verbosity(.detailed), SpokenMessage.verbosityLongest,
      ])

    harness.lines = []
    control.inject(transcript: "tips off")
    XCTAssertFalse(preferences.voiceTipsEnabled)
    control.inject(transcript: "tips on")
    XCTAssertTrue(preferences.voiceTipsEnabled)
    control.inject(transcript: "phone voice")
    XCTAssertFalse(preferences.useNaturalVoice)
    control.inject(transcript: "natural voice on")
    XCTAssertTrue(preferences.useNaturalVoice)
    harness.hasCloudKey = false
    control.inject(transcript: "natural voice on")
    XCTAssertEqual(
      harness.lines,
      [
        SpokenMessage.voiceTipsOff, SpokenMessage.voiceTipsOn, SpokenMessage.readNaturalVoiceOff, SpokenMessage.readNaturalVoiceOn,
        SpokenMessage.readNaturalVoiceOnNoKey,
      ])
  }

  func testReplaySetupByVoice() {
    preferences.onboardingCompleted = true
    _ = beginListening()
    harness.lines = []
    control.inject(transcript: "replay setup")
    XCTAssertFalse(preferences.onboardingCompleted)
    XCTAssertEqual(harness.lines, [SpokenMessage.replayingSetup])
  }

  func testSettingsListsTheSpokenSettings() {
    _ = beginListening()
    harness.lines = []
    control.inject(transcript: "settings")
    XCTAssertEqual(harness.lines.count, 1)
    XCTAssertTrue(harness.lines[0].hasPrefix("Settings you can say:"))
    XCTAssertTrue(harness.lines[0].contains("listen through glasses"))
  }

  func testListenThroughGlassesWithoutACameraSaysWhy() {
    _ = beginListening()
    harness.lines = []
    control.inject(transcript: "listen through glasses")
    XCTAssertEqual(harness.lines, [SpokenMessage.voiceGlassesMicNeedsCamera])
  }

  // MARK: The glasses mic offer

  func testTheFirstSessionOffersTheGlassesMicOnce() async {
    _ = beginListening()
    harness.lines = []
    _ = attachFakeGlasses(permission: .notDetermined)
    await settle()
    XCTAssertEqual(harness.lines, [SpokenMessage.voiceGlassesMicOffer])
    XCTAssertTrue(preferences.glassesMicOffered)
    XCTAssertNil(control.activePrompt, "non-blocking: read still works")
    control.inject(transcript: "no")
    XCTAssertEqual(harness.lines.last, SpokenMessage.voiceGlassesMicDeclined)

    control.detachGlasses()
    harness.lines = []
    _ = attachFakeGlasses(permission: .notDetermined)
    await settle()
    XCTAssertEqual(harness.lines, [], "asked once, ever")
  }

  func testNoGlassesMicOfferWhenItIsAlreadyAllowed() async {
    _ = beginListening()
    harness.lines = []
    _ = attachFakeGlasses(permission: .granted)
    await settle()
    XCTAssertEqual(harness.lines, [])
    XCTAssertFalse(preferences.glassesMicOffered)
  }

  // MARK: The yes/no question lapses

  func testAConfirmationExpiresSoALateYesDoesNothing() async throws {
    _ = beginListening()
    control.confirmTimeout = .milliseconds(50)
    var answers: [String] = []
    control.confirm(SpokenMessage.disconnectConfirm, onYes: { answers.append("yes") }, onNo: { answers.append("no") })
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertNil(control.activePrompt)
    control.inject(transcript: "yeah")
    XCTAssertEqual(answers, [])
  }

  func testAConfirmationEndsOnGoodbyeAndOnAScreenChange() {
    _ = beginListening()
    control.confirm(SpokenMessage.disconnectConfirm, onYes: {}, onNo: {})
    control.inject(transcript: "reader, goodbye")
    XCTAssertNil(control.activePrompt)

    control.wake()
    control.confirm(SpokenMessage.disconnectConfirm, onYes: {}, onNo: {})
    control.setScreen(.home) { _ in false }
    XCTAssertNil(control.activePrompt)
  }

  func testOtherCommandsDuringAConfirmationAskForYesOrNo() {
    _ = beginListening()
    control.confirm(SpokenMessage.disconnectConfirm, onYes: {}, onNo: {})
    harness.lines = []
    control.inject(transcript: "read")
    XCTAssertEqual(harness.lines, [SpokenMessage.voiceSayYesOrNo])
    harness.lines = []
    control.inject(transcript: "what time is the bus")  // conversation: still silent
    XCTAssertEqual(harness.lines, [])
  }

  // MARK: Permissions settled

  /// Either one refused counts as settled, as in the listening policy: nothing more will be asked.
  func testPermissionsPendingFollowsTheListeningPolicy() {
    XCTAssertTrue(VoiceControl.permissionsPending(mic: .notDetermined, speech: .notDetermined))
    XCTAssertTrue(VoiceControl.permissionsPending(mic: .granted, speech: .notDetermined))
    XCTAssertTrue(VoiceControl.permissionsPending(mic: .notDetermined, speech: .granted))
    XCTAssertFalse(VoiceControl.permissionsPending(mic: .notDetermined, speech: .denied))
    XCTAssertFalse(VoiceControl.permissionsPending(mic: .denied, speech: .notDetermined))
    XCTAssertFalse(VoiceControl.permissionsPending(mic: .granted, speech: .granted))
  }

  func testSayConnectIsNotStuckWhenSpeechWasRefused() {
    harness.phoneMic = .notDetermined
    harness.speech = .denied
    control.begin()
    control.setScreen(.welcome) { _ in false }
    var offered = false
    control.whenPermissionsSettled { offered = true }
    XCTAssertTrue(offered)
  }

  // MARK: A refused key

  func testNaturalVoiceOnSaysWhyAfterARefusedKey() {
    _ = beginListening()
    harness.cloudKeyRefused = true
    harness.lines = []
    control.inject(transcript: "natural voice on")
    XCTAssertEqual(harness.lines, [SpokenMessage.readNaturalVoiceOnKeyRefused])
  }

  // MARK: Listen again

  func testThePausedIndicatorOffersListenAgainAfterGoodbye() {
    let asleep = VoiceIndicatorModel.make(
      status: .paused, reason: SpokenMessage.voiceAsleep, listener: nil, micPermission: .granted, speechPermission: .granted,
      isSpeaking: false, heard: nil, canPrompt: true)
    XCTAssertEqual(asleep.fix, .listenAgain)
    let background = VoiceIndicatorModel.make(
      status: .paused, reason: VoicePauseReason.background.text, listener: nil, micPermission: .granted,
      speechPermission: .granted, isSpeaking: false, heard: nil, canPrompt: true)
    XCTAssertNil(background.fix)
  }
}

@MainActor
final class ReviewFixTests: XCTestCase {
  /// The read that raised an alert doesn't repeat it (the screen is saying it); a read started
  /// while it was already up does.
  func testAnAlertIsRepeatedOnlyIfItWasAlreadyUp() {
    XCTAssertEqual(TextReader.repromptLine("Say yes.", alreadyUpWhenReadStarted: true), "Say yes.")
    XCTAssertNil(TextReader.repromptLine("Say yes.", alreadyUpWhenReadStarted: false))
    XCTAssertNil(TextReader.repromptLine(nil, alreadyUpWhenReadStarted: true))
  }

  /// After "Camera access allowed", the read carries on only if nothing moved on.
  func testThePermissionReadCarriesOnOnlyIfNothingMovedOn() {
    XCTAssertTrue(CameraViewModel.shouldCarryOn(readTokenThen: 3, readTokenNow: 3, asleep: false))
    XCTAssertFalse(CameraViewModel.shouldCarryOn(readTokenThen: 3, readTokenNow: 4, asleep: false), "a stop or another read")
    XCTAssertFalse(CameraViewModel.shouldCarryOn(readTokenThen: 3, readTokenNow: 3, asleep: true), "goodbye")
  }

  func testStopAndCancelChangeTheReadToken() {
    let reader = TextReader()
    let start = reader.readToken
    reader.cancelPendingRead()
    XCTAssertNotEqual(reader.readToken, start)
    let afterCancel = reader.readToken
    reader.stop()
    XCTAssertNotEqual(reader.readToken, afterCancel)
  }

  func testAppearanceFollowsThePhoneUntilChosen() throws {
    let suite = "Appearance.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let appearance = ThemeAppearance(defaults: defaults)
    XCTAssertEqual(appearance.mode, .system)
    XCTAssertNil(ThemeAppearance.colorScheme(for: .system))
    XCTAssertEqual(ThemeAppearance.colorScheme(for: .dark), .dark)
    XCTAssertEqual(ThemeAppearance.colorScheme(for: .light), .light)
    XCTAssertEqual(ThemeAppearance.Mode.system.next, .dark)
    XCTAssertEqual(ThemeAppearance.Mode.dark.next, .light)
    XCTAssertEqual(ThemeAppearance.Mode.light.next, .system)
    appearance.mode = .light
    XCTAssertEqual(ThemeAppearance(defaults: defaults).mode, .light)
    for mode in ThemeAppearance.Mode.allCases {
      XCTAssertFalse(SpokenMessage.appearance(mode).isEmpty)
    }
  }

  /// Idle is a still frame, as are Reduce Motion and Low Power Mode; a moving ribbon pauses unseen.
  func testTheRibbonOnlyMovesWhenItMeansSomething() {
    XCTAssertFalse(VoiceRibbon.animates(.idle, reduceMotion: false, lowPower: false))
    XCTAssertFalse(VoiceRibbon.animates(.error, reduceMotion: false, lowPower: false))
    XCTAssertTrue(VoiceRibbon.animates(.listening, reduceMotion: false, lowPower: false))
    XCTAssertTrue(VoiceRibbon.animates(.speaking, reduceMotion: false, lowPower: false))
    XCTAssertFalse(VoiceRibbon.animates(.listening, reduceMotion: true, lowPower: false))
    XCTAssertFalse(VoiceRibbon.animates(.listening, reduceMotion: false, lowPower: true))
    XCTAssertFalse(VoiceRibbon.timelinePaused(visible: true, active: true))
    XCTAssertTrue(VoiceRibbon.timelinePaused(visible: false, active: true))
    XCTAssertTrue(VoiceRibbon.timelinePaused(visible: true, active: false))
  }

  func testASiriRequestIsStillTakenWithWakeInIt() {
    let router = LaunchActionRouter()
    router.request(.read)
    XCTAssertEqual(router.consume(), .read)
  }
}

@MainActor
final class SpokenSettingsTests: XCTestCase {
  func testVerbositySteps() {
    XCTAssertEqual(Verbosity.normal.shorter, .short)
    XCTAssertNil(Verbosity.short.shorter)
    XCTAssertEqual(Verbosity.normal.longer, .detailed)
    XCTAssertNil(Verbosity.detailed.longer)
  }

  func testVerbosityPersists() throws {
    let suite = "SpokenSettings.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = A11yPreferences(defaults: defaults)
    _ = SpokenSettings.apply(.moreDetail, preferences: preferences, hasCloudKey: true)
    XCTAssertEqual(A11yPreferences(defaults: defaults).verbosity, .detailed)
  }

  func testOneTimeFlagsPersist() throws {
    let suite = "SpokenSettings.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = A11yPreferences(defaults: defaults)
    XCTAssertFalse(preferences.interruptTipHeard)
    XCTAssertFalse(preferences.glassesMicOffered)
    preferences.interruptTipHeard = true
    preferences.glassesMicOffered = true
    let again = A11yPreferences(defaults: defaults)
    XCTAssertTrue(again.interruptTipHeard)
    XCTAssertTrue(again.glassesMicOffered)
  }

  func testNewSpokenLinesSayWhatToSayNotWhatToTap() {
    let lines = [
      SpokenMessage.welcomeConnect, SpokenMessage.welcomeAlreadyConnected, SpokenMessage.welcomeRetry,
      SpokenMessage.readNothingToNavigate, SpokenMessage.metaAIRegistrationRequest, SpokenMessage.firmwareUpdateNeeded,
      SpokenMessage.firmwareUpdateNeeded(deviceName: "Oakley Meta HSTN"), SpokenMessage.glassesAppUpdateNeeded,
      SpokenMessage.readCloudKeySavedVoiceOff,
    ]
    for line in lines {
      XCTAssertFalse(line.lowercased().contains("tap "), line)
      XCTAssertTrue(line.contains("Say ") || line.contains("say "), line)
    }
    XCTAssertTrue(SpokenMessage.metaAIRegistrationRequest.contains("Say yes to finish connecting, or not now."))
    XCTAssertEqual(SpokenMessage.voiceInterruptTip, "To interrupt me, say reader, stop.")
    XCTAssertEqual(SpokenMessage.disconnectConfirm, "Disconnect your glasses? Say yes or no.")
    XCTAssertEqual(SpokenMessage.voiceGlassesMicOffer, "Want me to listen through your glasses? Say yes or no.")
    XCTAssertEqual(SpokenMessage.voiceDialogOnScreen, "A dialog is on screen. With VoiceOver, double-tap Allow.")
  }

  func testAlertHintsMatchWhatTheAlertsAccept() {
    XCTAssertTrue(CameraProblem.spokenWithHint(message: "Camera stopped.", action: .tryAgain).hasSuffix(SpokenMessage.alertSayTryAgain))
    XCTAssertTrue(CameraProblem.spokenWithHint(message: "Hot.", action: nil).hasSuffix(SpokenMessage.alertSayOK))
    XCTAssertTrue(CameraProblem.voiceCommands(for: .updateGlassesApp).contains(.update))
    XCTAssertTrue(WearablesAlertAction.openFirmwareUpdate.voiceCommands.contains(.update))
    XCTAssertTrue(WearablesAlertAction.reconnect.voiceCommands.contains(.connect))
  }
}

// MARK: - The real GlassesSpeechListener against the mock

@MainActor
final class GlassesSpeechListenerMockTests: XCTestCase {
  private var mock: MockGlasses?
  private var selector: AutoDeviceSelector?

  override func setUp() async throws {
    try await super.setUp()
    try? Wearables.configure()
    MockDeviceKit.shared.enable()
    let glasses = try MockDeviceKit.shared.pairGlasses(model: .rayBanMeta)
    glasses.powerOn()
    glasses.don()
    mock = glasses
    MockDeviceKit.shared.permissions.set(.microphone, .granted)
    try await Task.sleep(for: .seconds(1))
  }

  override func tearDown() async throws {
    await MockDeviceKit.shared.disable()
    mock = nil
    try await super.tearDown()
  }

  private func startedSession() async throws -> DeviceSession {
    // The selector only knows a device once its stream has reported one, as in CameraViewModel.
    let selector = AutoDeviceSelector(wearables: Wearables.shared)
    self.selector = selector
    for await device in selector.activeDeviceStream() where device != nil { break }
    let session = try Wearables.shared.createSession(deviceSelector: selector)
    try session.start()
    for _ in 0..<100 where session.state != .started {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(session.state, .started)
    return session
  }

  private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<100 where !condition() {
      try await Task.sleep(for: .milliseconds(50))
    }
  }

  func testFinalTranscriptsGetThroughIncludingNoScore() async throws {
    let glasses = try XCTUnwrap(mock)
    let session = try await startedSession()
    defer { session.stop() }

    let listener = GlassesSpeechListener(session: session)
    var events: [SpeechListenerEvent] = []
    listener.onEvent = { events.append($0) }
    listener.start()
    let speech = glasses.services.speech
    try await waitUntil { speech.isListening }
    XCTAssertTrue(speech.isListening, "the mock should be listening")
    try await waitUntil { events.contains(.started) }
    XCTAssertTrue(events.contains(.started))

    speech.simulateTranscription(text: "partial stop", isFinal: false, confidence: 0.9)
    speech.simulateTranscription(text: "read this", isFinal: true, confidence: 0.9)
    try await waitUntil { events.contains(.transcript("read this")) }
    XCTAssertTrue(events.contains(.transcript("read this")))
    XCTAssertFalse(events.contains(.transcript("partial stop")))

    listener.stop()
    try await waitUntil { !speech.isListening }
    XCTAssertFalse(speech.isListening, "stop should end listening")
  }

  func testMockErrorIsReportedAsFailure() async throws {
    let glasses = try XCTUnwrap(mock)
    let session = try await startedSession()
    defer { session.stop() }

    let listener = GlassesSpeechListener(session: session)
    var events: [SpeechListenerEvent] = []
    listener.onEvent = { events.append($0) }
    listener.start()
    let speech = glasses.services.speech
    try await waitUntil { speech.isListening }
    speech.simulateError(errorCode: 1, message: "test")
    try await waitUntil {
      events.contains { if case .failed = $0 { true } else { false } }
    }
    XCTAssertTrue(events.contains { if case .failed = $0 { true } else { false } })
  }
}
