/*
 * ConversationTests - the pure parts of the Realtime conversation: the session.update the server
 * gets, the page context and its trimming, incoming event parsing (audio, transcripts, the
 * goodbye tool, errors), barge-in arithmetic, and the "talk" voice command
 *
 * No network and no audio.
 */

@testable import CameraAccess
import Foundation
// ast-grep-ignore: swift-testing/swift/no-new-xctest
import XCTest

final class ConversationTests: XCTestCase {
  // MARK: Outgoing

  func testURLCarriesTheModel() {
    XCTAssertEqual(RealtimeConfig.url()?.absoluteString, "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1")
  }

  func testSessionUpdateAsksForAudioWithSemanticVADAndBargeIn() throws {
    let event = RealtimeOutgoing.sessionUpdate(pageText: "Call me Ishmael.")
    XCTAssertEqual(event["type"] as? String, "session.update")
    let session = try XCTUnwrap(event["session"] as? [String: Any])
    XCTAssertEqual(session["type"] as? String, "realtime")
    XCTAssertEqual(session["output_modalities"] as? [String], ["audio"])
    let audio = try XCTUnwrap(session["audio"] as? [String: Any])
    let input = try XCTUnwrap(audio["input"] as? [String: Any])
    let turn = try XCTUnwrap(input["turn_detection"] as? [String: Any])
    XCTAssertEqual(turn["type"] as? String, "semantic_vad")
    XCTAssertEqual(turn["interrupt_response"] as? Bool, true)
    let format = try XCTUnwrap(input["format"] as? [String: Any])
    XCTAssertEqual(format["type"] as? String, "audio/pcm")
    XCTAssertEqual(format["rate"] as? Int, 24_000)
    let output = try XCTUnwrap(audio["output"] as? [String: Any])
    XCTAssertEqual(output["voice"] as? String, "marin")
    let tools = try XCTUnwrap(session["tools"] as? [[String: Any]])
    XCTAssertEqual(tools.first?["name"] as? String, RealtimeConfig.endToolName)
    XCTAssertNotNil(RealtimeOutgoing.encode(event), "must serialise to JSON")
  }

  func testInstructionsIncludeThePage() {
    let text = RealtimeOutgoing.instructions(pageText: "  Call me Ishmael.  ")
    XCTAssertTrue(text.contains("<<<PAGE\nCall me Ishmael.\nPAGE>>>"))
  }

  func testInstructionsWithoutAPageSuggestReadingFirst() {
    let text = RealtimeOutgoing.instructions(pageText: "   ")
    XCTAssertFalse(text.contains("<<<PAGE"))
    XCTAssertTrue(text.contains("say read"))
  }

  func testLongPageIsCutAtASentenceEnd() throws {
    let page = String(repeating: "Short one. ", count: 1_000)
    let trimmed = try XCTUnwrap(RealtimeOutgoing.trimmedPage(page, limit: 25))
    XCTAssertEqual(trimmed, "Short one. Short one.")
  }

  func testAppendAudioIsBase64() {
    let event = RealtimeOutgoing.appendAudio(Data([1, 2, 3]))
    XCTAssertEqual(event["type"] as? String, "input_audio_buffer.append")
    XCTAssertEqual(event["audio"] as? String, "AQID")
  }

  func testTruncateNeverGoesNegative() {
    let event = RealtimeOutgoing.truncate(itemID: "item_1", audioEndMs: -40)
    XCTAssertEqual(event["audio_end_ms"] as? Int, 0)
    XCTAssertEqual(event["item_id"] as? String, "item_1")
  }

  // MARK: Incoming

  func testAudioDelta() {
    let event = RealtimeEvent.parse(#"{"type":"response.output_audio.delta","item_id":"item_9","delta":"AQID"}"#)
    XCTAssertEqual(event, .audioDelta(itemID: "item_9", pcm16: Data([1, 2, 3])))
  }

  func testTranscripts() {
    XCTAssertEqual(
      RealtimeEvent.parse(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"what does ephemeral mean"}"#),
      .userTranscript("what does ephemeral mean"))
    XCTAssertEqual(
      RealtimeEvent.parse(#"{"type":"response.output_audio_transcript.delta","delta":"Short-"}"#), .assistantTranscriptDelta("Short-"))
  }

  func testSpeechStartedIsTheBargeInSignal() {
    XCTAssertEqual(RealtimeEvent.parse(#"{"type":"input_audio_buffer.speech_started","audio_start_ms":120}"#), .speechStarted)
  }

  func testGoodbyeToolCallArrivesInResponseDone() {
    let json = #"{"type":"response.done","response":{"status":"completed","output":[{"type":"message"},{"type":"function_call","name":"end_conversation","call_id":"call_7","arguments":"{}"}]}}"#
    XCTAssertEqual(RealtimeEvent.parse(json), .functionCall(name: "end_conversation", callID: "call_7"))
  }

  func testPlainResponseDone() {
    XCTAssertEqual(RealtimeEvent.parse(#"{"type":"response.done","response":{"output":[{"type":"message"}]}}"#), .responseDone)
  }

  func testErrors() {
    XCTAssertEqual(RealtimeEvent.parse(#"{"type":"error","error":{"code":"invalid_api_key"}}"#), .failed(.unauthorized))
    XCTAssertEqual(RealtimeEvent.parse(#"{"type":"error","error":{"code":"insufficient_quota"}}"#), .failed(.rateLimited))
    // Cancelling a reply that already finished is routine after a barge-in.
    XCTAssertEqual(RealtimeEvent.parse(#"{"type":"error","error":{"code":"response_cancel_not_active"}}"#), .other("error"))
  }

  func testGarbageIsIgnored() {
    XCTAssertEqual(RealtimeEvent.parse("not json"), .other("unparsed"))
    XCTAssertEqual(RealtimeEvent.parse(#"{"type":"rate_limits.updated"}"#), .other("rate_limits.updated"))
  }

  // MARK: Barge-in

  func testHeardMsSubtractsWhatWasStillBuffered() {
    var playback = RealtimePlayback()
    playback.queued(itemID: "a", bytes: 48_000)  // 1 s at 24 kHz PCM16
    playback.queued(itemID: "a", bytes: 48_000)
    XCTAssertEqual(playback.heardMs(unplayedBytes: 24_000), 1_500)
    XCTAssertEqual(playback.heardMs(unplayedBytes: 200_000), 0)
  }

  func testNewItemRestartsTheCount() {
    var playback = RealtimePlayback()
    playback.queued(itemID: "a", bytes: 48_000)
    playback.queued(itemID: "b", bytes: 4_800)
    XCTAssertEqual(playback.itemID, "b")
    XCTAssertEqual(playback.heardMs(unplayedBytes: 0), 100)
  }

  // MARK: Voice command

  func testTalkIsACommandOnCameraAndHome() {
    for screen in [VoiceScreen.camera, .home] {
      let context = VoiceContext(screen: screen)
      XCTAssertEqual(VoiceCommandParser.parse("let's talk", context: context), .command(.talk))
      XCTAssertEqual(VoiceCommandParser.parse("I have a question", context: context), .command(.talk))
      XCTAssertEqual(VoiceCommandParser.parse("can we talk about this", context: context), .command(.talk))
    }
    XCTAssertNotEqual(VoiceCommandParser.parse("talk", context: VoiceContext(screen: .welcome)), .command(.talk))
  }

  func testCommandListenerPausesDuringAConversation() {
    var inputs = VoiceListenerPolicy.Inputs(phoneMic: .granted, speechRecognition: .granted)
    XCTAssertEqual(VoiceListenerPolicy.decide(inputs), .phone)
    inputs.inConversation = true
    XCTAssertEqual(VoiceListenerPolicy.decide(inputs), .paused(.conversation))
  }
}
