/*
 * CloudReadingTests - the pure parts of cloud reading: the Responses stream's SSE lines, the
 * SPEAKUP_NOTE reply, sentences split from streamed text (including sentences that cross chunk
 * boundaries), the key lookup order, the request bodies and error mapping, and PCM decoding
 *
 * No network: requests are built and inspected, never sent.
 */

import AVFoundation
@testable import CameraAccess
import Foundation
// ast-grep-ignore: swift-testing/swift/no-new-xctest
import XCTest

/// Feeds `chunks` one at a time, then finishes. Returns every sentence in order.
private func split(_ chunks: [String]) -> (sentences: [String], note: String?) {
  var splitter = StreamingSentenceSplitter()
  var sentences: [String] = []
  for chunk in chunks { sentences += splitter.append(chunk) }
  sentences += splitter.finish()
  return (sentences, splitter.note)
}

private func json(_ data: Data?) throws -> [String: Any] {
  let data = try XCTUnwrap(data)
  return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

final class OpenAISSETests: XCTestCase {
  func testTextDeltaLine() {
    let line = #"data: {"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"content_index":0,"delta":"Hello\n\nWorld"}"#
    XCTAssertEqual(OpenAISSE.event(fromLine: line), .textDelta("Hello\n\nWorld"))
  }

  func testDataWithoutSpaceAfterColon() {
    let line = #"data:{"type":"response.output_text.delta","delta":"Hi"}"#
    XCTAssertEqual(OpenAISSE.event(fromLine: line), .textDelta("Hi"))
  }

  func testNonDataLinesCarryNothing() {
    XCTAssertNil(OpenAISSE.event(fromLine: "event: response.output_text.delta"))
    XCTAssertNil(OpenAISSE.event(fromLine: ""))
    XCTAssertNil(OpenAISSE.event(fromLine: ": keep-alive"))
  }

  func testOtherEventsAreIgnored() {
    XCTAssertEqual(OpenAISSE.event(fromLine: #"data: {"type":"response.created","response":{}}"#), .ignored)
    XCTAssertEqual(OpenAISSE.event(fromLine: #"data: {"type":"response.output_text.done","text":"Hi"}"#), .ignored)
    XCTAssertEqual(OpenAISSE.event(fromLine: "data: not json"), .ignored)
  }

  func testCompletedAndIncompleteEndTheText() {
    XCTAssertEqual(OpenAISSE.event(fromLine: #"data: {"type":"response.completed","response":{}}"#), .completed)
    XCTAssertEqual(
      OpenAISSE.event(fromLine: #"data: {"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}"#),
      .completed)
    XCTAssertEqual(OpenAISSE.event(fromLine: "data: [DONE]"), .completed)
  }

  func testFailuresMapToErrors() {
    XCTAssertEqual(
      OpenAISSE.event(fromLine: #"data: {"type":"response.failed","response":{"error":{"code":"rate_limit_exceeded","message":"x"}}}"#),
      .failed(.rateLimited))
    XCTAssertEqual(
      OpenAISSE.event(fromLine: #"data: {"type":"response.failed","response":{"error":{"code":"server_error"}}}"#), .failed(.server))
    XCTAssertEqual(OpenAISSE.event(fromLine: #"data: {"type":"error","code":"invalid_api_key","message":"x"}"#), .failed(.unauthorized))
  }
}

final class SpeakUpNoteTests: XCTestCase {
  func testNoteIsHeldBackAndReturned() {
    let result = split(["SPEAKUP_NOTE: I can't see any text. ", "Try holding the page a bit further away."])
    XCTAssertEqual(result.sentences, [])
    XCTAssertEqual(result.note, "I can't see any text. Try holding the page a bit further away.")
  }

  func testMarkerSplitAcrossChunksAndLeadingWhitespace() {
    let result = split(["\n SPEAK", "UP_NO", "TE: The page is blurred."])
    XCTAssertEqual(result.sentences, [])
    XCTAssertEqual(result.note, "The page is blurred.")
  }

  func testTextThatOnlyStartsLikeTheMarkerIsRead() {
    let result = split(["SPEAK", "ER notes. Second line."])
    XCTAssertEqual(result.sentences, ["SPEAKER notes.", "Second line."])
    XCTAssertNil(result.note)
  }

  func testShortTextIsDecidedAtTheEnd() {
    let result = split(["SPEAK"])
    XCTAssertEqual(result.sentences, ["SPEAK"])
    XCTAssertNil(result.note)
  }

  func testNoteWaitsForMoreTextBeforeDeciding() {
    var splitter = StreamingSentenceSplitter()
    XCTAssertEqual(splitter.append("SPEAKUP"), [])
    XCTAssertFalse(splitter.isNote)
    XCTAssertEqual(splitter.append("_NOTE: Too dark."), [])
    XCTAssertTrue(splitter.isNote)
    XCTAssertEqual(splitter.finish(), [])
    XCTAssertEqual(splitter.note, "Too dark.")
  }

  func testEmptyNoteFallsBackToNil() {
    XCTAssertNil(split(["SPEAKUP_NOTE:   "]).note)
  }
}

final class StreamingSentenceSplitterTests: XCTestCase {
  private let page = "The quick brown fox. It jumped over Dr. Smith's dog.\n\nA new paragraph starts here! Does it end? Yes."

  func testSentencesCrossingChunkBoundaries() {
    let result = split(["The quick bro", "wn fox. It jum", "ped over Dr", ". Smith's dog.", "\n\nA new para", "graph starts here! Does it end? Yes."])
    XCTAssertEqual(
      result.sentences,
      ["The quick brown fox.", "It jumped over Dr. Smith's dog.", "A new paragraph starts here!", "Does it end?", "Yes."])
  }

  func testSentenceIsReleasedAsSoonAsTheNextWordStarts() {
    var splitter = StreamingSentenceSplitter()
    XCTAssertEqual(splitter.append("The quick brown fox."), [], "the next word decides whether the full stop ends it")
    XCTAssertEqual(splitter.append(" I"), ["The quick brown fox."])
    XCTAssertEqual(splitter.append("t jumped."), [])
    XCTAssertEqual(splitter.finish(), ["It jumped."])
  }

  func testLowercaseNextWordKeepsTheSentenceGoing() {
    XCTAssertEqual(split(["It costs approx", ". ten pounds. Then"]).sentences, ["It costs approx. ten pounds.", "Then"])
  }

  func testNewlineEndsAHeadingOrListItem() {
    var splitter = StreamingSentenceSplitter()
    XCTAssertEqual(splitter.append("Ingredients\n2 eggs\n"), ["Ingredients", "2 eggs"])
    XCTAssertEqual(splitter.append("1 cup flour"), [])
    XCTAssertEqual(splitter.finish(), ["1 cup flour"])
  }

  func testCharacterByCharacterMatchesAllAtOnce() {
    let whole = split([page]).sentences
    let byCharacter = split(page.map { String($0) }).sentences
    XCTAssertEqual(byCharacter, whole)
    XCTAssertEqual(whole.count, 5)
  }

  func testLongUnpunctuatedTextIsCut() {
    let words = (1...90).map { "word\($0)" }.joined(separator: " ")
    let sentences = split([words]).sentences
    XCTAssertEqual(sentences.count, 3)
    XCTAssertEqual(sentences.first?.split(separator: " ").count, SentenceSplitter.maxWords)
  }

  func testWhitespaceOnlyGivesNothing() {
    XCTAssertEqual(split(["  \n\n ", "  "]).sentences, [])
  }

  func testCloudSentenceRendersPlainText() {
    let sentence = CloudSentence.rendered("Take 2 tablets daily.", verbosity: .normal, earconsEnabled: true)
    XCTAssertEqual(sentence.display, "Take 2 tablets daily.")
    XCTAssertEqual(CloudSentence.speechText(sentence), "Take 2 tablets daily.")
    XCTAssertNil(sentence.withheld, "the cloud gives no confidence, so nothing counts as unsure")
  }
}

/// A key store that holds one key in memory.
private final class MemoryKeyStore: OpenAIKeyStore, @unchecked Sendable {
  private let lock = NSLock()
  private var key: String?

  init(_ key: String? = nil) { self.key = key }

  func readKey() -> String? { lock.withLock { key } }

  func saveKey(_ key: String) -> Bool {
    lock.withLock { self.key = key }
    return true
  }

  func deleteKey() { lock.withLock { key = nil } }
}

@MainActor
final class OpenAIKeyTests: XCTestCase {
  func testStoredKeyWinsOverBundled() {
    let key = OpenAIKey.resolve(store: MemoryKeyStore("sk-stored"), infoDictionary: ["OpenAIAPIKey": "sk-bundled"])
    XCTAssertEqual(key, "sk-stored")
  }

  func testBundledKeyWhenNothingStored() {
    XCTAssertEqual(OpenAIKey.resolve(store: MemoryKeyStore(), infoDictionary: ["OpenAIAPIKey": "sk-bundled"]), "sk-bundled")
  }

  func testBlankStoredKeyFallsThroughToBundled() {
    XCTAssertEqual(OpenAIKey.resolve(store: MemoryKeyStore("  \n"), infoDictionary: ["OpenAIAPIKey": " sk-bundled\n"]), "sk-bundled")
  }

  func testMissingEmptyOrUnexpandedMeansNoKey() {
    XCTAssertNil(OpenAIKey.resolve(store: MemoryKeyStore(), infoDictionary: nil))
    XCTAssertNil(OpenAIKey.resolve(store: MemoryKeyStore(), infoDictionary: [:]))
    XCTAssertNil(OpenAIKey.resolve(store: MemoryKeyStore(), infoDictionary: ["OpenAIAPIKey": ""]))
    XCTAssertNil(OpenAIKey.resolve(store: MemoryKeyStore(), infoDictionary: ["OpenAIAPIKey": "$(OPENAI_API_KEY)"]))
  }

  func testPastedKeyIsTrimmed() {
    XCTAssertEqual(OpenAIKey.normalized("  sk-abc\n"), "sk-abc")
  }

  func testCloudReadingSaveAndRemove() throws {
    let suiteName = "OpenAIKeyTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = MemoryKeyStore()
    let reading = CloudReading(store: store, infoDictionary: [:], preferences: A11yPreferences(defaults: defaults))
    XCTAssertFalse(reading.hasKey)
    XCTAssertFalse(reading.hasStoredKey)

    XCTAssertFalse(reading.saveKey("   "))
    XCTAssertTrue(reading.saveKey(" sk-pasted "))
    XCTAssertEqual(store.readKey(), "sk-pasted")
    XCTAssertTrue(reading.hasKey)
    XCTAssertTrue(reading.hasStoredKey)

    reading.removeKey()
    XCTAssertFalse(reading.hasKey)
    XCTAssertFalse(reading.hasStoredKey)
  }

  func testRemovingThePastedKeyLeavesTheBundledOne() throws {
    let suiteName = "OpenAIKeyTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let reading = CloudReading(
      store: MemoryKeyStore("sk-pasted"), infoDictionary: ["OpenAIAPIKey": "sk-bundled"], preferences: A11yPreferences(defaults: defaults))
    reading.removeKey()
    XCTAssertTrue(reading.hasKey)
    XCTAssertFalse(reading.hasStoredKey)
  }

  func testTestsAlwaysReadOnThePhone() throws {
    let suiteName = "OpenAIKeyTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = A11yPreferences(defaults: defaults)
    XCTAssertTrue(preferences.useNaturalVoice, "on by default")
    let reading = CloudReading(store: MemoryKeyStore("sk-pasted"), infoDictionary: [:], preferences: preferences)
    XCTAssertTrue(reading.hasKey)
    XCTAssertFalse(reading.isEnabled, "unit and UI tests keep the deterministic on-device path")
    XCTAssertNil(reading.client())
  }

  func testNaturalVoicePreferencePersists() throws {
    let suiteName = "OpenAIKeyTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    A11yPreferences(defaults: defaults).useNaturalVoice = false
    XCTAssertFalse(A11yPreferences(defaults: defaults).useNaturalVoice)
  }
}

final class OpenAIRequestTests: XCTestCase {
  func testTranscriptionRequestShape() throws {
    let request = try OpenAIClient(apiKey: "test-key").transcriptionRequest(jpeg: Data([1, 2, 3]))
    XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")

    let body = try json(request.httpBody)
    XCTAssertEqual(body["model"] as? String, OpenAIClient.transcriptionModel)
    XCTAssertEqual(body["stream"] as? Bool, true)
    XCTAssertEqual(body["store"] as? Bool, false)
    XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, OpenAIClient.reasoningEffort)
    let instructions = try XCTUnwrap(body["instructions"] as? String)
    XCTAssertTrue(instructions.contains("SPEAKUP_NOTE:"))

    let input = try XCTUnwrap(body["input"] as? [[String: Any]])
    XCTAssertEqual(input.count, 1)
    XCTAssertEqual(input[0]["role"] as? String, "user")
    let content = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
    let image = try XCTUnwrap(content.first { $0["type"] as? String == "input_image" })
    XCTAssertEqual(image["image_url"] as? String, "data:image/jpeg;base64,AQID")
    XCTAssertEqual(image["detail"] as? String, "high")
  }

  func testSpeechRequestShape() throws {
    let request = try OpenAIClient(apiKey: "test-key").speechRequest(text: "Hello there.")
    XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/audio/speech")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")

    let body = try json(request.httpBody)
    XCTAssertEqual(body["model"] as? String, "gpt-4o-mini-tts")
    XCTAssertEqual(body["voice"] as? String, OpenAIClient.voice)
    XCTAssertEqual(body["input"] as? String, "Hello there.")
    XCTAssertEqual(body["response_format"] as? String, "pcm")
    XCTAssertFalse((body["instructions"] as? String ?? "").isEmpty)
  }

  func testSpeechRequestSendsTheSpeed() throws {
    let body = try json(OpenAIClient(apiKey: "test-key").speechRequest(text: "Hi.", speed: 1.3).httpBody)
    XCTAssertEqual(body["speed"] as? Double, 1.3)
    let plain = try json(OpenAIClient(apiKey: "test-key").speechRequest(text: "Hi.").httpBody)
    XCTAssertEqual(plain["speed"] as? Double, 1.0)
  }

  /// Faster and slower move the cloud voice too: the default rate is 1.0, the ends are half and
  /// double speed, always inside what OpenAI accepts.
  func testSpeedFollowsTheSavedRate() {
    let base = AVSpeechUtteranceDefaultSpeechRate
    XCTAssertEqual(OpenAIClient.speechSpeed(forRate: base), 1.0)
    XCTAssertEqual(OpenAIClient.speechSpeed(forRate: AVSpeechUtteranceMinimumSpeechRate), 0.5)
    XCTAssertEqual(OpenAIClient.speechSpeed(forRate: AVSpeechUtteranceMaximumSpeechRate), 2.0)
    XCTAssertEqual(OpenAIClient.speechSpeed(forRate: base + 0.05), 1.1, accuracy: 0.001)
    XCTAssertEqual(OpenAIClient.speechSpeed(forRate: base - 0.05), 0.95, accuracy: 0.001)
    // Out of range is clamped, and the order is kept.
    XCTAssertEqual(OpenAIClient.speechSpeed(forRate: -1), 0.5)
    XCTAssertEqual(OpenAIClient.speechSpeed(forRate: 5), 2.0)
    var last = 0.0
    for step in 0...20 {
      let speed = OpenAIClient.speechSpeed(forRate: Float(step) / 20)
      XCTAssertGreaterThanOrEqual(speed, last)
      XCTAssertTrue(OpenAIClient.speedRange.contains(speed))
      last = speed
    }
  }

  func testEmptyKeyIsRefused() {
    XCTAssertThrowsError(try OpenAIClient(apiKey: " ").speechRequest(text: "Hi")) { error in
      XCTAssertEqual(error as? OpenAIError, .noKey)
    }
  }

  func testStatusAndErrorMapping() {
    XCTAssertEqual(OpenAIError.from(status: 401), .unauthorized)
    XCTAssertEqual(OpenAIError.from(status: 403), .unauthorized)
    XCTAssertEqual(OpenAIError.from(status: 429), .rateLimited)
    XCTAssertEqual(OpenAIError.from(status: 500), .server)
    XCTAssertEqual(OpenAIError.from(status: 400), .server)
    XCTAssertEqual(OpenAIError.mapped(URLError(.timedOut)) as? OpenAIError, .network)
    XCTAssertEqual(OpenAIError.mapped(URLError(.notConnectedToInternet)) as? OpenAIError, .network)
    XCTAssertTrue(OpenAIError.mapped(URLError(.cancelled)) is CancellationError)
    XCTAssertTrue(OpenAIError.mapped(CancellationError()) is CancellationError)
    XCTAssertEqual(OpenAIError.from(code: "insufficient_quota"), .quota)
    XCTAssertEqual(OpenAIError.from(code: "rate_limit_exceeded"), .rateLimited)
    XCTAssertEqual(OpenAIError.from(code: "invalid_api_key"), .unauthorized)
  }

  /// Each failure says what happened; only "couldn't reach" is the general line.
  func testEachCloudFailureHasItsLine() {
    XCTAssertEqual(
      SpokenMessage.readCloudFallback(for: .unauthorized),
      "The reading service didn't accept the key. Reading on the phone for now; set a new key in Settings.")
    XCTAssertEqual(SpokenMessage.readCloudFallback(for: .quota), SpokenMessage.readCloudQuota)
    XCTAssertEqual(SpokenMessage.readCloudFallback(for: .rateLimited), SpokenMessage.readCloudBusy)
    XCTAssertEqual(SpokenMessage.readCloudFallback(for: .network), SpokenMessage.readCloudFallback)
    XCTAssertEqual(SpokenMessage.readCloudFallback(for: .server), SpokenMessage.readCloudFallback)
    XCTAssertEqual(SpokenMessage.readCloudFallback(for: nil), SpokenMessage.readCloudFallback)
    let lines = Set([OpenAIError.unauthorized, .quota, .rateLimited, .network].map { SpokenMessage.readCloudFallback(for: $0) })
    XCTAssertEqual(lines.count, 4)
  }
}

@MainActor
final class CloudKeyRefusalTests: XCTestCase {
  private func reading(_ key: String = "sk-pasted") throws -> (CloudReading, () -> Void) {
    let suiteName = "CloudKeyRefusal.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    let reading = CloudReading(store: MemoryKeyStore(key), infoDictionary: [:], preferences: A11yPreferences(defaults: defaults))
    return (reading, { defaults.removePersistentDomain(forName: suiteName) })
  }

  /// A refused key stops the cloud for the session; a new key starts it again.
  func testARefusedKeyIsNotTriedAgainUntilANewOneIsSaved() throws {
    let (reading, cleanUp) = try reading()
    defer { cleanUp() }
    XCTAssertFalse(reading.keyRefused)
    TextReader.noteCloudFailure(.network, cloud: reading)
    TextReader.noteCloudFailure(.quota, cloud: reading)
    XCTAssertFalse(reading.keyRefused, "only a refused key stops the cloud")
    TextReader.noteCloudFailure(.unauthorized, cloud: reading)
    XCTAssertTrue(reading.keyRefused)
    XCTAssertNil(reading.client())
    XCTAssertTrue(reading.saveKey("sk-new"))
    XCTAssertFalse(reading.keyRefused)
  }

  func testRemovingTheKeyClearsTheRefusal() throws {
    let (reading, cleanUp) = try reading()
    defer { cleanUp() }
    reading.noteKeyRefused()
    reading.removeKey()
    XCTAssertFalse(reading.keyRefused)
  }
}

/// After stop, "continue" starts the stopped sentence again instead of skipping it; "resume" carries
/// on; neither does anything odd at the end or with nothing read.
@MainActor
final class ReadResumeTests: XCTestCase {
  func testContinueAfterStopRestartsTheSentence() {
    XCTAssertEqual(TextReader.continueStep(phase: .stopped, hasSentences: true), .restartCurrent)
    XCTAssertEqual(TextReader.continueStep(phase: .reading, hasSentences: true), .next)
    XCTAssertEqual(TextReader.continueStep(phase: .finished, hasSentences: true), .next)
    XCTAssertEqual(TextReader.continueStep(phase: .idle, hasSentences: false), .sayNothingRead)
  }

  func testResume() {
    XCTAssertEqual(TextReader.resumeStep(phase: .stopped, hasSentences: true), .restartCurrent)
    XCTAssertEqual(TextReader.resumeStep(phase: .reading, hasSentences: true), .keepGoing)
    XCTAssertEqual(TextReader.resumeStep(phase: .preparing, hasSentences: true), .keepGoing)
    XCTAssertEqual(TextReader.resumeStep(phase: .finished, hasSentences: true), .sayAtEnd)
    XCTAssertEqual(TextReader.resumeStep(phase: .stopped, hasSentences: false), .sayNothingRead)
  }
}

final class PCM16DecoderTests: XCTestCase {
  func testDecodesLittleEndianAcrossOddChunks() {
    var decoder = PCM16Decoder()
    // 0x4000 = 16384 (0.5), 0xC000 = -16384 (-0.5), split mid-sample.
    XCTAssertEqual(decoder.samples(from: Data([0x00, 0x40, 0x00])), [0.5])
    XCTAssertEqual(decoder.samples(from: Data([0xC0])), [-0.5])
    XCTAssertEqual(decoder.samples(from: Data([0xFF, 0x7F])), [Float(32_767) / 32_768])
  }
}
