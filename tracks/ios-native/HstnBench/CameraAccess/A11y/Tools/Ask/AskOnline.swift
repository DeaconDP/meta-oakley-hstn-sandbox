/*
 * AskOnline - the optional cloud answer for open questions ("why did he do that?")
 *
 * Off unless the user has set an OpenAI key (Settings, or a build-time key; OpenAIKey decides),
 * and never under test. Only open questions go online: definitions, spelling, who, recap and find
 * always stay on the phone. A request is made only when the user asks one, and "Asking online." is
 * said first. Sent: the question and the text heard so far (the last 12,000 characters at most).
 * Never an image. The model is told to answer only from the text, in one to three short spoken
 * sentences, and otherwise to reply exactly "The text doesn't say.", which becomes .notInText.
 *
 * Reuses OpenAIKey for the key, and OpenAIClient's host check, model, session and error mapping.
 * OpenAIClient itself only has the page-transcription and speech requests, so the one text request
 * is built here (suggested for OpenAIClient in notes/watch-and-ask-ios.md). Non-streaming: answers
 * are a sentence or three. Request building and reply handling are pure and unit-tested; no live
 * request has been made.
 */

import Foundation

/// What Ask comes back with. The tool picks the words.
enum AskResult: Equatable, Sendable {
  case answer(String)
  /// The text that was read doesn't say.
  case notInText
  /// Nothing has been read yet, so there's nothing to ask about.
  case nothingRead
  /// Something went wrong; the reason is for the log, not for speaking.
  case failed(String)
}

/// Somewhere that can reason over the text: OpenAI in the app, a fake in tests.
protocol AskOnline: Sendable {
  func ask(question: String, text: String) async -> AskResult
}

struct OpenAIAskOnline: AskOnline {
  typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

  static let notInTextReply = "The text doesn't say."
  static let maxOutputTokens = 2048

  static let instructions = """
    You answer a blind or low-vision person's question about text that was just read aloud to them. \
    Answer only from the text given. Do not add facts from outside it. \
    Reply in one to three short, plain sentences meant to be heard, with no Markdown, lists or quotes longer than a sentence. \
    If the text doesn't answer the question, reply with exactly: \(notInTextReply)
    """

  let apiKey: String
  var transport: Transport

  init(apiKey: String, transport: Transport? = nil) {
    self.apiKey = apiKey
    self.transport = transport ?? { request in try await OpenAIClient.defaultSession.data(for: request) }
  }

  /// The client for the app: a key is set and this isn't a test run. nil means stay on the phone.
  static func configured(
    store: any OpenAIKeyStore = KeychainKeyStore(), infoDictionary: [String: Any]? = Bundle.main.infoDictionary
  ) -> OpenAIAskOnline? {
    guard !LaunchOptions.isAutomatedTest, let key = OpenAIKey.resolve(store: store, infoDictionary: infoDictionary) else {
      return nil
    }
    return OpenAIAskOnline(apiKey: key)
  }

  static func body(question: String, text: String) -> [String: Any] {
    [
      "model": OpenAIClient.transcriptionModel,
      "store": false,
      "reasoning": ["effort": OpenAIClient.reasoningEffort],
      "max_output_tokens": maxOutputTokens,
      "instructions": instructions,
      "input": [
        [
          "role": "user",
          "content": [
            ["type": "input_text", "text": "The text:\n\(text)\n\nThe question: \(question)"]
          ],
        ]
      ],
    ]
  }

  func request(question: String, text: String) throws -> URLRequest {
    let url = OpenAIClient.responsesURL
    // The key only ever goes to OpenAI.
    guard url.scheme == "https", url.host() == OpenAIClient.host else { throw OpenAIError.server }
    guard OpenAIKey.normalized(apiKey) != nil else { throw OpenAIError.noKey }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: Self.body(question: question, text: text))
    return request
  }

  func ask(question: String, text: String) async -> AskResult {
    do {
      let (data, response) = try await transport(try request(question: question, text: text))
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      return Self.result(status: status, body: data)
    } catch {
      let mapped = OpenAIError.mapped(error)
      return .failed((mapped as? OpenAIError)?.logName ?? "cancelled")
    }
  }

  /// A Responses API reply as an answer. The text is the message's output_text parts; a refusal,
  /// an error status or a body without text is a failure.
  static func result(status: Int, body: Data) -> AskResult {
    guard status == 200 else { return .failed(OpenAIError.from(status: status).logName) }
    guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      let output = json["output"] as? [[String: Any]]
    else { return .failed("bad_json") }
    var parts: [String] = []
    for item in output where item["type"] as? String == "message" {
      for content in item["content"] as? [[String: Any]] ?? [] {
        switch content["type"] as? String {
        case "output_text": if let text = content["text"] as? String { parts.append(text) }
        case "refusal": return .failed("refusal")
        default: continue
        }
      }
    }
    let answer = parts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !answer.isEmpty else { return .failed("empty") }
    let bare = answer.trimmingCharacters(in: CharacterSet(charactersIn: " .\"'")).lowercased()
    if bare == notInTextReply.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() { return .notInText }
    return .answer(answer)
  }
}
