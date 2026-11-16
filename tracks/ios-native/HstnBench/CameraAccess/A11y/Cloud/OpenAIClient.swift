/*
 * OpenAIClient - the two OpenAI calls behind cloud reading: page photo to text, text to voice
 *
 * The user asked for "a photo of each page, transcribe the text, then read the transcription
 * using a fast, casual conversational voice". Both calls stream, because the wait is what the
 * user hears:
 * - Transcription: Responses API with the photo as a base64 JPEG data URL, `stream: true`.
 *   `response.output_text.delta` events arrive as server-sent events, so the first sentence can go
 *   to the voice while the model is still writing the rest of the page.
 * - Speech: /v1/audio/speech with raw PCM (24 kHz, 16-bit little-endian, mono), read with
 *   URLSession.bytes so CloudVoicePlayer starts on the first chunk instead of the whole file.
 *
 * Plain URLSession, no SDK. An ephemeral session: no cache, no cookies, nothing of the photo or
 * the key written to disk. The key goes in the Authorization header and only ever to
 * api.openai.com (request(_:body:) refuses any other host); it is never logged.
 *
 * Cancelling the consuming task cancels the network task (AsyncThrowingStream's onTermination).
 * Errors come out as OpenAIError, or CancellationError for a cancel, so callers can tell "the
 * user moved on" from "the service failed".
 *
 * The model names and the voice are constants here so they are easy to change.
 */

import Foundation

enum OpenAIError: Error, Equatable, Sendable {
  case noKey
  case unauthorized
  case network
  case rateLimited
  case server

  /// For the log. Never includes the key or the response body.
  var logName: String {
    switch self {
    case .noKey: "no_key"
    case .unauthorized: "unauthorized"
    case .network: "network"
    case .rateLimited: "rate_limited"
    case .server: "server"
    }
  }

  static func from(status: Int) -> OpenAIError {
    switch status {
    case 401, 403: .unauthorized
    case 429: .rateLimited
    default: .server
    }
  }

  /// An `error.code` from a response body or a stream error event.
  static func from(code: String?) -> OpenAIError {
    switch code {
    case "invalid_api_key": .unauthorized
    case "rate_limit_exceeded", "insufficient_quota": .rateLimited
    default: .server
    }
  }

  /// Anything thrown by URLSession or the stream, as an OpenAIError or CancellationError.
  static func mapped(_ error: any Error) -> any Error {
    if error is CancellationError { return error }
    if let error = error as? OpenAIError { return error }
    if let error = error as? URLError {
      return error.code == .cancelled ? CancellationError() : OpenAIError.network
    }
    return OpenAIError.network
  }
}

// MARK: - Server-sent events

/// What one line of the Responses stream means to the reader.
enum OpenAIStreamEvent: Equatable, Sendable {
  case textDelta(String)
  /// The response is over (completed, or incomplete because it hit the token limit: what arrived
  /// is still read).
  case completed
  case failed(OpenAIError)
  case ignored
}

enum OpenAISSE {
  /// One line of the event stream. nil for lines that carry no data (`event:` lines, comments,
  /// blank lines). Every Responses event is a single `data:` line of JSON with a `type`, so lines
  /// can be handled one at a time; the blank line that ends an event isn't needed (and
  /// AsyncLineSequence drops blank lines anyway).
  static func event(fromLine line: String) -> OpenAIStreamEvent? {
    guard line.hasPrefix("data:") else { return nil }
    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
    if payload == "[DONE]" { return .completed }
    guard let data = payload.data(using: .utf8),
      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let type = object["type"] as? String
    else { return .ignored }
    switch type {
    case "response.output_text.delta":
      return .textDelta(object["delta"] as? String ?? "")
    case "response.completed", "response.incomplete":
      return .completed
    case "response.failed":
      let response = object["response"] as? [String: Any]
      let error = response?["error"] as? [String: Any]
      return .failed(.from(code: error?["code"] as? String))
    case "error":
      let nested = object["error"] as? [String: Any]
      return .failed(.from(code: (object["code"] as? String) ?? (nested?["code"] as? String)))
    default:
      return .ignored
    }
  }
}

// MARK: - Client

struct OpenAIClient: Sendable {
  static let host = "api.openai.com"
  static let responsesURL = URL(string: "https://api.openai.com/v1/responses")!
  static let speechURL = URL(string: "https://api.openai.com/v1/audio/speech")!

  static let transcriptionModel = "gpt-5.4-mini"
  /// "low" is accepted across the GPT-5 family; try "minimal" or "none" here if the model takes
  /// it, for a faster first word.
  static let reasoningEffort = "low"
  static let maxOutputTokens = 4096
  static let speechModel = "gpt-4o-mini-tts"
  static let voice = "coral"
  static let speechSampleRate: Double = 24_000
  /// PCM bytes per chunk handed to the player: 100 ms at 24 kHz, 16-bit mono.
  static let speechChunkBytes = 4_800

  /// The first thing in a reply that has no text to read, followed by a spoken hint.
  static let noteMarker = "SPEAKUP_NOTE:"

  static let transcriptionInstructions = """
    You transcribe a photo of printed text for a blind or low-vision person, who will hear it read aloud.
    Transcribe the printed text exactly as written, in natural reading order. Do not summarise, correct, translate or add anything.
    Merge words hyphenated across line breaks, and join lines that belong to the same paragraph.
    Leave out running headers, running footers and page numbers. Do not describe images, logos or layout.
    If a word or number can't be read with confidence, write [unclear] in its place. Never guess numbers, doses or prices.
    Output plain text only, no Markdown, with a blank line between paragraphs. Put headings, list items and table rows on their own lines.
    If there is no readable text, or the page is badly cut off or blurred, reply with only one line that starts with \(noteMarker) followed by a short, friendly hint to say out loud, for example: \(noteMarker) I can't see any text. Try holding the page a bit further away.
    """

  static let speechInstructions = """
    Read this aloud like a friend reading to you: quick, relaxed and conversational, natural pace on the fast side, \
    no dramatic pauses. Don't add or skip words. Say [unclear] as "unclear".
    """

  /// No cache or cookie storage; idle timeout per request, an overall cap per resource.
  static let defaultSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 90
    configuration.waitsForConnectivity = false
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    return URLSession(configuration: configuration)
  }()

  let apiKey: String
  var session: URLSession = OpenAIClient.defaultSession

  // MARK: Requests

  static func transcriptionBody(jpegBase64: String) -> [String: Any] {
    [
      "model": transcriptionModel,
      "stream": true,
      "store": false,
      "reasoning": ["effort": reasoningEffort],
      "max_output_tokens": maxOutputTokens,
      "instructions": transcriptionInstructions,
      "input": [
        [
          "role": "user",
          "content": [
            ["type": "input_text", "text": "Transcribe the text on this page."],
            ["type": "input_image", "image_url": "data:image/jpeg;base64,\(jpegBase64)", "detail": "high"],
          ],
        ]
      ],
    ]
  }

  static func speechBody(text: String) -> [String: Any] {
    [
      "model": speechModel,
      "voice": voice,
      "input": text,
      "instructions": speechInstructions,
      "response_format": "pcm",
    ]
  }

  func transcriptionRequest(jpeg: Data) throws -> URLRequest {
    var request = try request(Self.responsesURL, body: Self.transcriptionBody(jpegBase64: jpeg.base64EncodedString()))
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    return request
  }

  func speechRequest(text: String) throws -> URLRequest {
    try request(Self.speechURL, body: Self.speechBody(text: text))
  }

  private func request(_ url: URL, body: [String: Any]) throws -> URLRequest {
    // The key only ever goes to OpenAI.
    guard url.scheme == "https", url.host() == Self.host else { throw OpenAIError.server }
    guard OpenAIKey.normalized(apiKey) != nil else { throw OpenAIError.noKey }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return request
  }

  // MARK: Streams

  /// The page's text as it is written. Finishes at the end of the response; throws OpenAIError,
  /// or CancellationError when the consumer was cancelled.
  func transcriptionDeltas(jpeg: Data) -> AsyncThrowingStream<String, any Error> {
    let request: URLRequest
    do {
      request = try transcriptionRequest(jpeg: jpeg)
    } catch {
      return AsyncThrowingStream { $0.finish(throwing: OpenAIError.mapped(error)) }
    }
    let session = session
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let (bytes, response) = try await session.bytes(for: request)
          try await Self.check(response, bytes: bytes)
          for try await line in bytes.lines {
            switch OpenAISSE.event(fromLine: line) {
            case .textDelta(let text):
              continuation.yield(text)
            case .completed:
              continuation.finish()
              return
            case .failed(let error):
              throw error
            case .ignored, nil:
              continue
            }
          }
          // The connection closed without a completed event: the text may be cut short.
          throw OpenAIError.network
        } catch {
          continuation.finish(throwing: OpenAIError.mapped(error))
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Raw PCM (24 kHz, Int16 LE, mono) for `text`, in chunks of about `speechChunkBytes`. A chunk
  /// may end half way through a sample; PCM16Decoder carries the odd byte.
  func speechPCM(text: String) -> AsyncThrowingStream<Data, any Error> {
    let request: URLRequest
    do {
      request = try speechRequest(text: text)
    } catch {
      return AsyncThrowingStream { $0.finish(throwing: OpenAIError.mapped(error)) }
    }
    let session = session
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let (bytes, response) = try await session.bytes(for: request)
          try await Self.check(response, bytes: bytes)
          var chunk = Data()
          chunk.reserveCapacity(Self.speechChunkBytes)
          for try await byte in bytes {
            chunk.append(byte)
            if chunk.count >= Self.speechChunkBytes {
              continuation.yield(chunk)
              chunk = Data()
              chunk.reserveCapacity(Self.speechChunkBytes)
            }
          }
          if !chunk.isEmpty { continuation.yield(chunk) }
          continuation.finish()
        } catch {
          continuation.finish(throwing: OpenAIError.mapped(error))
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Throws the mapped error for anything but 200. Reads a little of the body for the error code.
  private static func check(_ response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
    guard let http = response as? HTTPURLResponse else { throw OpenAIError.network }
    guard http.statusCode != 200 else { return }
    if http.statusCode == 401 || http.statusCode == 403 { throw OpenAIError.unauthorized }
    var body = Data()
    for try await byte in bytes {
      body.append(byte)
      if body.count >= 4_096 { break }
    }
    let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    let code = (object?["error"] as? [String: Any])?["code"] as? String
    let fromCode = OpenAIError.from(code: code)
    throw fromCode == .server ? OpenAIError.from(status: http.statusCode) : fromCode
  }
}
