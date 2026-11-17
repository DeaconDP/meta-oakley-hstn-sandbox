/*
 * CloudTranscript - the pure steps between OpenAI's streamed text and the reader's sentences,
 * plus the photo preparation and the PCM decoding the cloud path needs
 *
 * StreamingSentenceSplitter takes the transcription a delta at a time and hands out each
 * sentence as soon as it is certain to be complete, so the first sentence goes to the voice while
 * the model is still writing the rest of the page. A sentence is complete when:
 * - a newline follows it (the model puts paragraphs, headings and list items on their own lines);
 * - its last word ends a sentence by SentenceSplitter.endsSentence, which needs the first letter
 *   of the next word ("Dr." / "etc. and"), so a sentence ending at a chunk boundary waits for
 *   the next delta;
 * - it reaches SentenceSplitter.maxWords, so unpunctuated text still pages;
 * - or the stream has finished.
 * A reply that starts with OpenAIClient.noteMarker isn't text to read: it is held back and
 * returned as `note`, a hint to speak instead ("I can't see any text...").
 *
 * Nothing here touches the network, audio or the UI, so all of it is unit-tested (CloudReadingTests).
 */

import Foundation
import UIKit

struct StreamingSentenceSplitter {
  /// Set once the whole reply was a note; the hint to speak, without the marker.
  private(set) var note: String?

  private var buffer = ""
  private enum Mode { case undecided, text, note }
  private var mode = Mode.undecided
  private let marker: String

  init(marker: String = OpenAIClient.noteMarker) {
    self.marker = marker
  }

  /// True while the reply is (so far) a note: no sentences will come.
  var isNote: Bool { mode == .note }

  /// Adds a delta; returns the sentences it completed.
  mutating func append(_ delta: String) -> [String] {
    buffer += delta
    return drain(final: false)
  }

  /// The stream is over: returns whatever was left as sentences, and sets `note` for a note.
  mutating func finish() -> [String] {
    drain(final: true)
  }

  private mutating func drain(final: Bool) -> [String] {
    if mode == .undecided {
      let head = buffer.drop(while: \.isWhitespace)
      if head.count >= marker.count || final || !marker.hasPrefix(head) {
        mode = head.hasPrefix(marker) ? .note : .text
      } else {
        return []
      }
    }
    if mode == .note {
      if final {
        let hint = buffer.drop(while: \.isWhitespace).dropFirst(marker.count)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        note = hint.isEmpty ? nil : hint
        buffer = ""
      }
      return []
    }
    return takeSentences(final: final)
  }

  private struct Token {
    var text: String
    var end: String.Index
    /// Whitespace follows it in what has arrived (so the word is whole).
    var closed: Bool
    var newlineAfter: Bool
  }

  private mutating func takeSentences(final: Bool) -> [String] {
    let tokens = tokenize()
    var sentences: [String] = []
    var current: [String] = []
    var consumed = buffer.startIndex
    for (index, token) in tokens.enumerated() {
      guard token.closed || final else { break }
      current.append(token.text)
      let next = index + 1 < tokens.count ? tokens[index + 1] : nil
      let boundary: Bool
      if token.newlineAfter || current.count >= SentenceSplitter.maxWords {
        boundary = true
      } else if let next {
        boundary = SentenceSplitter.endsSentence(token.text, next: next.text)
      } else if final {
        boundary = true
      } else {
        // The last whole word so far: whether it ends a sentence depends on the next word.
        break
      }
      if boundary {
        let sentence = current.joined(separator: " ")
        // A note in the middle of text (the model shouldn't, but) is never read out as text.
        if !sentence.hasPrefix(marker) { sentences.append(sentence) }
        current = []
        consumed = token.end
      }
    }
    buffer = String(buffer[consumed...])
    return sentences
  }

  private func tokenize() -> [Token] {
    var tokens: [Token] = []
    var index = buffer.startIndex
    while index < buffer.endIndex {
      while index < buffer.endIndex, buffer[index].isWhitespace {
        if buffer[index].isNewline, !tokens.isEmpty { tokens[tokens.count - 1].newlineAfter = true }
        index = buffer.index(after: index)
      }
      guard index < buffer.endIndex else { break }
      let start = index
      while index < buffer.endIndex, !buffer[index].isWhitespace { index = buffer.index(after: index) }
      tokens.append(Token(text: String(buffer[start..<index]), end: index, closed: index < buffer.endIndex, newlineAfter: false))
    }
    return tokens
  }
}

// MARK: - Sentences for the reader

enum CloudSentence {
  /// A transcribed sentence in the reader's type. The cloud gives no per-word confidence, so every
  /// word counts as sure; "[unclear]" (the model's mark for an unreadable word) stays in the text.
  static func rendered(_ text: String, verbosity: Verbosity, earconsEnabled: Bool) -> RenderedSentence {
    let words = text.split(whereSeparator: \.isWhitespace).map { ReadWord(text: String($0), confidence: 1) }
    return ReadSpeech.render(words, verbosity: verbosity, earconsEnabled: earconsEnabled)
  }

  /// What the cloud voice is given for a sentence: its spoken chunks as one line.
  static func speechText(_ sentence: RenderedSentence) -> String {
    sentence.chunks.map(\.text).joined(separator: " ")
  }
}

// MARK: - Photo

enum CloudImage {
  static let longEdge: CGFloat = 2048
  static let quality: CGFloat = 0.8

  /// The photo as a JPEG with its long edge at most `longEdge` pixels, orientation applied.
  static func jpeg(_ image: UIImage, longEdge: CGFloat = longEdge, quality: CGFloat = quality) -> Data? {
    let width = image.size.width * image.scale
    let height = image.size.height * image.scale
    let longest = max(width, height)
    guard longest > 0 else { return nil }
    let factor = min(1, longEdge / longest)
    let target = CGSize(width: (width * factor).rounded(), height: (height * factor).rounded())
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(size: target, format: format)
    return renderer.jpegData(withCompressionQuality: quality) { _ in
      image.draw(in: CGRect(origin: .zero, size: target))
    }
  }
}

// MARK: - PCM

/// 16-bit little-endian PCM bytes to Float samples. Chunks may split a sample; the odd byte is
/// carried to the next chunk.
struct PCM16Decoder {
  private var carry: UInt8?

  mutating func samples(from data: Data) -> [Float] {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(data.count + 1)
    if let carry { bytes.append(carry) }
    carry = nil
    bytes.append(contentsOf: data)
    if bytes.count % 2 == 1 { carry = bytes.removeLast() }
    var samples: [Float] = []
    samples.reserveCapacity(bytes.count / 2)
    var index = 0
    while index + 1 < bytes.count {
      let value = Int16(bitPattern: UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8))
      samples.append(Float(value) / 32_768)
      index += 2
    }
    return samples
  }
}
