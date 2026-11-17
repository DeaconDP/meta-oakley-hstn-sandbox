/*
 * RealtimeProtocol - the pure half of the conversation mode: what goes over the OpenAI Realtime
 * WebSocket and what comes back
 *
 * Same API, model and voice as ElizaQuest (Docs/voice-chat.md there): the GA Realtime interface
 * (no OpenAI-Beta header), `gpt-realtime-2.1`, voice `marin`, 24 kHz mono PCM16 both ways,
 * `semantic_vad` turn detection with barge-in, and `near_field` noise reduction off by default
 * because the phone is held at arm's length (`far_field`).
 *
 * Conversation is for talking *about* what was read: "what does that word mean?", "who wrote
 * this?", "sum it up". Reading a page word for word stays with TextReader (the speech endpoint
 * reads exactly; a conversational model paraphrases). So the page goes in the instructions as
 * context, and the model is told to answer briefly, in speech, and to say when the text doesn't say.
 *
 * One tool: `end_conversation`, which the model calls when the user says goodbye, so leaving
 * works by voice without a wake word or a command grammar.
 *
 * Nothing here touches the network, audio or the UI (RealtimeProtocolTests).
 */

import Foundation

enum RealtimeConfig {
  static let model = "gpt-realtime-2.1"
  static let voice = "marin"
  static let sampleRate = 24_000
  static let endpoint = "wss://api.openai.com/v1/realtime"
  static let endToolName = "end_conversation"
  /// Silence after the assistant finishes before the conversation closes by itself.
  static let idleTimeout: TimeInterval = 45
  /// The page text sent as context. A long page is cut at a sentence end before this.
  static let maxContextCharacters = 6_000

  static func url(model: String = model) -> URL? {
    var components = URLComponents(string: endpoint)
    components?.queryItems = [URLQueryItem(name: "model", value: model)]
    return components?.url
  }
}

// MARK: - Outgoing

enum RealtimeOutgoing {
  /// The persona, with the page read last (if any) as context.
  static func instructions(pageText: String?) -> String {
    var lines = [
      "You are SpeakUp, a reading companion for someone who is blind or has low vision, talking through their smart glasses.",
      "Speak naturally, warmly and briefly: one to three short sentences per turn unless they ask for more. No lists, no markdown, nothing visual.",
      "They may ask about the page they just had read to them: meanings of words, who or what something is, a summary, or what a part said.",
      "If the page doesn't say, say so plainly rather than guessing. Never give medication doses or read out money amounts you can't see in the text.",
      "If they ask you to read the page word for word, tell them to say goodbye and then say read.",
      "When they say goodbye, thanks that's all, or that they're done, say a short goodbye and call \(RealtimeConfig.endToolName).",
    ]
    if let page = trimmedPage(pageText) {
      lines.append("The page they just had read, between the markers:\n<<<PAGE\n\(page)\nPAGE>>>")
    } else {
      lines.append("Nothing has been read yet this session, so answer generally, and suggest they say read to have a page read first if they ask about one.")
    }
    return lines.joined(separator: "\n")
  }

  /// The page, cut at a sentence end before the limit. nil when there's nothing to send.
  static func trimmedPage(_ text: String?, limit: Int = RealtimeConfig.maxContextCharacters) -> String? {
    guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
    guard text.count > limit else { return text }
    let head = String(text.prefix(limit))
    if let end = head.lastIndex(where: { ".!?".contains($0) }) {
      return String(head[...end])
    }
    return head
  }

  static func sessionUpdate(pageText: String?, voice: String = RealtimeConfig.voice, bargeIn: Bool = true) -> [String: Any] {
    let format: [String: Any] = ["type": "audio/pcm", "rate": RealtimeConfig.sampleRate]
    let session: [String: Any] = [
      "type": "realtime",
      "output_modalities": ["audio"],
      "instructions": instructions(pageText: pageText),
      "audio": [
        "input": [
          "format": format,
          "turn_detection": [
            "type": "semantic_vad",
            "eagerness": "auto",
            "create_response": true,
            "interrupt_response": bargeIn,
          ],
          "noise_reduction": ["type": "far_field"],
          "transcription": ["model": "gpt-4o-mini-transcribe"],
        ],
        "output": ["format": format, "voice": voice],
      ],
      "tools": [
        [
          "type": "function",
          "name": RealtimeConfig.endToolName,
          "description": "End the conversation after saying goodbye, when the user is done.",
          "parameters": ["type": "object", "properties": [String: Any]()],
        ]
      ],
      "tool_choice": "auto",
    ]
    return ["type": "session.update", "session": session]
  }

  /// The assistant speaks first: a one-line hello that offers to talk about the page.
  static func greeting(hasPage: Bool) -> [String: Any] {
    let prompt = hasPage
      ? "Greet them in one short sentence and invite a question about the page."
      : "Greet them in one short sentence and ask what they'd like to talk about."
    return ["type": "response.create", "response": ["instructions": prompt]]
  }

  static func appendAudio(_ pcm16: Data) -> [String: Any] {
    ["type": "input_audio_buffer.append", "audio": pcm16.base64EncodedString()]
  }

  /// After a barge-in: the model's history keeps only what was actually heard.
  static func truncate(itemID: String, audioEndMs: Int) -> [String: Any] {
    ["type": "conversation.item.truncate", "item_id": itemID, "content_index": 0, "audio_end_ms": max(0, audioEndMs)]
  }

  static func functionOutput(callID: String) -> [String: Any] {
    ["type": "conversation.item.create", "item": ["type": "function_call_output", "call_id": callID, "output": "{\"ok\":true}"]]
  }

  static func encode(_ event: [String: Any]) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: event) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}

// MARK: - Incoming

enum RealtimeEvent: Equatable, Sendable {
  case sessionReady
  /// The user started talking (barge-in point).
  case speechStarted
  case speechStopped
  case userTranscript(String)
  /// Assistant audio: 24 kHz mono PCM16, for the item being spoken.
  case audioDelta(itemID: String, pcm16: Data)
  case assistantTranscriptDelta(String)
  case assistantTranscriptDone(String)
  case responseDone
  case functionCall(name: String, callID: String)
  case failed(OpenAIError)
  case other(String)

  static func parse(_ text: String) -> RealtimeEvent {
    guard let data = text.data(using: .utf8),
      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let type = json["type"] as? String
    else { return .other("unparsed") }

    switch type {
    case "session.created", "session.updated":
      return .sessionReady
    case "input_audio_buffer.speech_started":
      return .speechStarted
    case "input_audio_buffer.speech_stopped":
      return .speechStopped
    case "conversation.item.input_audio_transcription.completed":
      return .userTranscript(json["transcript"] as? String ?? "")
    case "response.output_audio.delta":
      guard let delta = json["delta"] as? String, let pcm = Data(base64Encoded: delta) else { return .other(type) }
      return .audioDelta(itemID: json["item_id"] as? String ?? "", pcm16: pcm)
    case "response.output_audio_transcript.delta":
      return .assistantTranscriptDelta(json["delta"] as? String ?? "")
    case "response.output_audio_transcript.done":
      return .assistantTranscriptDone(json["transcript"] as? String ?? "")
    case "response.done":
      // Tool calls arrive as function_call items in the finished response's output.
      let output = (json["response"] as? [String: Any])?["output"] as? [[String: Any]] ?? []
      if let call = output.first(where: { $0["type"] as? String == "function_call" }) {
        return .functionCall(name: call["name"] as? String ?? "", callID: call["call_id"] as? String ?? "")
      }
      return .responseDone
    case "error":
      let error = json["error"] as? [String: Any]
      let code = error?["code"] as? String
      // A cancel with nothing to cancel is routine after a barge-in, not a failure.
      if code == "response_cancel_not_active" { return .other(type) }
      return .failed(OpenAIError.from(code: code))
    default:
      return .other(type)
    }
  }
}

// MARK: - Barge-in bookkeeping

/// Tracks how much of the assistant's current item has been played, so a barge-in can truncate the
/// model's memory to what the user actually heard.
struct RealtimePlayback: Equatable, Sendable {
  private(set) var itemID: String?
  private(set) var bytesQueued = 0

  mutating func queued(itemID: String, bytes: Int) {
    if itemID != self.itemID {
      self.itemID = itemID
      bytesQueued = 0
    }
    bytesQueued += bytes
  }

  /// Milliseconds heard: queued audio minus what was still buffered when it stopped.
  func heardMs(unplayedBytes: Int) -> Int {
    let played = max(0, bytesQueued - unplayedBytes)
    return played * 1000 / (RealtimeConfig.sampleRate * 2)
  }

  mutating func reset() {
    itemID = nil
    bytesQueued = 0
  }
}
