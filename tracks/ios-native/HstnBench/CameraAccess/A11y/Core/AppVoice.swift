/*
 * AppVoice - the one voice the app speaks with
 *
 * Both the Announcer and TtsReply speak with a female British English voice, whatever the
 * system language or region. It picks the best quality en-GB female voice installed (premium,
 * then enhanced, then the default), preferring Serena, Kate, Stephanie and Martha in that order.
 * Better voices are downloaded in Settings > Accessibility > Spoken Content > Voices > English.
 * If no en-GB female voice is installed it falls back to any en-GB voice, then to the system's
 * default English voice.
 */

import AVFoundation

enum AppVoice {
  private static let preferredNames = ["Serena", "Kate", "Stephanie", "Martha"]

  /// Looked up once; the lookup is slow enough to delay the first word.
  static let shared: AVSpeechSynthesisVoice? = {
    let british = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-GB" }
    let female = british.filter { $0.gender == .female }
    let pool = female.isEmpty ? british : female

    func rank(_ voice: AVSpeechSynthesisVoice) -> (Int, Int) {
      let nameRank = preferredNames.firstIndex { voice.name.hasPrefix($0) } ?? preferredNames.count
      return (voice.quality.rawValue, -nameRank)
    }

    return pool.max { rank($0) < rank($1) }
      ?? AVSpeechSynthesisVoice(language: "en-GB")
      ?? AVSpeechSynthesisVoice(language: "en-US")
  }()
}
