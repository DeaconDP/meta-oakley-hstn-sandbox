/*
 * LetterExplainOnline - the optional AI explanation of a letter ("explain online", "explain in Polish")
 *
 * Off unless the user has set an OpenAI key (OpenAIKey decides), and never under test. A request
 * is made only when the user asks for it, and MailTool says first that it's asking online and
 * that only the text is sent. Sent: the letter's text (Letter.safeText: an amount that couldn't
 * be read for sure is already replaced by words, so the model can't see a guessed figure) and
 * the language to answer in. Never the photo, never the sender's details apart from what's in the
 * text. The model is told to use only the text, to say when the letter doesn't say who, what,
 * how much or by when, never to work out an amount, and never to call a letter genuine or safe.
 *
 * Same request pattern as AskOnline (OpenAIClient's host check, model, session and error
 * mapping; the Responses API, store: false). Request building and reply handling are pure and
 * unit-tested; no live request has been made from tests.
 */

import Foundation

enum LetterExplainResult: Equatable, Sendable {
  case explanation(String)
  /// Something went wrong; the reason is for the log and to pick the spoken line.
  case failed(String)
}

protocol LetterExplainOnline: Sendable {
  func explain(text: String, language: String?) async -> LetterExplainResult
}

struct OpenAILetterExplainer: LetterExplainOnline {
  typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

  static let maxOutputTokens = 2048
  /// Letters are short; this keeps a long multi-page one bounded.
  static let maxTextCharacters = 12_000

  static func instructions(language: String?) -> String {
    let answerIn = language.map { "Write the whole explanation in \($0)." } ?? "Write in plain British English."
    return """
      You explain a letter to a blind or low-vision person, in plain, simple words meant to be heard. \
      Use only the letter's text that you are given. Do not add facts from outside it. \
      Say who it is from, what it is about, what it asks the reader to do, any amount to pay and any date to act by. \
      If the letter doesn't say one of these, say that the letter doesn't say it. \
      Never guess, estimate or work out an amount. If the text says "an amount I can't read for sure", say that the amount couldn't be read. \
      Never say a letter is genuine, real or safe. If it asks for gift cards, crypto, passwords or bank details, or pushes the reader to pay at once, \
      say it has signs of a scam and to check with someone they trust. \
      No Markdown, lists or headings. At most six short sentences. \(answerIn)
      """
  }

  let apiKey: String
  var transport: Transport

  init(apiKey: String, transport: Transport? = nil) {
    self.apiKey = apiKey
    self.transport = transport ?? { request in try await OpenAIClient.defaultSession.data(for: request) }
  }

  /// The client for the app: a key is set and this isn't a test run. nil means stay on the phone.
  static func configured(
    store: any OpenAIKeyStore = KeychainKeyStore(), infoDictionary: [String: Any]? = Bundle.main.infoDictionary
  ) -> OpenAILetterExplainer? {
    guard !LaunchOptions.isAutomatedTest, let key = OpenAIKey.resolve(store: store, infoDictionary: infoDictionary) else {
      return nil
    }
    return OpenAILetterExplainer(apiKey: key)
  }

  /// The request body: the text and the instructions, nothing else.
  static func body(text: String, language: String?) -> [String: Any] {
    [
      "model": OpenAIClient.transcriptionModel,
      "store": false,
      "reasoning": ["effort": OpenAIClient.reasoningEffort],
      "max_output_tokens": maxOutputTokens,
      "instructions": instructions(language: language),
      "input": [
        [
          "role": "user",
          "content": [
            ["type": "input_text", "text": "The letter:\n\(String(text.suffix(maxTextCharacters)))"]
          ],
        ]
      ],
    ]
  }

  func request(text: String, language: String?) throws -> URLRequest {
    let url = OpenAIClient.responsesURL
    // The key only ever goes to OpenAI.
    guard url.scheme == "https", url.host() == OpenAIClient.host else { throw OpenAIError.server }
    guard OpenAIKey.normalized(apiKey) != nil else { throw OpenAIError.noKey }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: Self.body(text: text, language: language))
    return request
  }

  func explain(text: String, language: String?) async -> LetterExplainResult {
    do {
      let (data, response) = try await transport(try request(text: text, language: language))
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      return Self.result(status: status, body: data)
    } catch {
      let mapped = OpenAIError.mapped(error)
      return .failed((mapped as? OpenAIError)?.logName ?? "cancelled")
    }
  }

  /// The reply's output_text parts; a refusal, an error status or no text is a failure.
  static func result(status: Int, body: Data) -> LetterExplainResult {
    switch OpenAIAskOnline.result(status: status, body: body) {
    case .answer(let text): .explanation(text)
    case .notInText: .explanation(OpenAIAskOnline.notInTextReply)
    case .failed(let reason): .failed(reason)
    case .nothingRead: .failed("empty")
    }
  }
}

// MARK: - Languages

enum LetterLanguages {
  /// Spoken name (normalised) -> the name the model is given.
  static let names: [String: String] = [
    "polish": "Polish", "urdu": "Urdu", "punjabi": "Punjabi", "panjabi": "Punjabi", "bengali": "Bengali", "bangla": "Bengali",
    "gujarati": "Gujarati", "arabic": "Arabic", "romanian": "Romanian", "spanish": "Spanish", "portuguese": "Portuguese",
    "french": "French", "italian": "Italian", "german": "German", "lithuanian": "Lithuanian", "latvian": "Latvian",
    "russian": "Russian", "ukrainian": "Ukrainian", "turkish": "Turkish", "chinese": "Chinese (Simplified)",
    "mandarin": "Chinese (Simplified)", "cantonese": "Cantonese (Traditional Chinese)", "hindi": "Hindi", "tamil": "Tamil",
    "somali": "Somali", "farsi": "Persian", "persian": "Persian", "kurdish": "Kurdish", "pashto": "Pashto", "dari": "Dari",
    "tigrinya": "Tigrinya", "amharic": "Amharic", "welsh": "Welsh", "irish": "Irish", "greek": "Greek", "bulgarian": "Bulgarian",
    "hungarian": "Hungarian", "czech": "Czech", "slovak": "Slovak", "albanian": "Albanian", "vietnamese": "Vietnamese",
    "tagalog": "Tagalog", "filipino": "Filipino", "japanese": "Japanese", "korean": "Korean", "dutch": "Dutch",
    "swedish": "Swedish", "malayalam": "Malayalam", "telugu": "Telugu", "nepali": "Nepali", "swahili": "Swahili",
    "yoruba": "Yoruba", "hebrew": "Hebrew", "thai": "Thai", "croatian": "Croatian", "serbian": "Serbian", "english": "English",
  ]

  /// The phone's first language when it isn't English, as a name for the model; nil for English.
  static func phoneLanguage(preferred: [String] = Locale.preferredLanguages) -> String? {
    guard let first = preferred.first else { return nil }
    let code = Locale(identifier: first).language.languageCode?.identifier ?? String(first.prefix(2))
    guard code != "en" else { return nil }
    return Locale(identifier: "en_GB").localizedString(forLanguageCode: code)
  }
}
