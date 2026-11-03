/*
 * ReadText - recognized text as the reader sees it, and the pure steps from OCR lines to
 * sentences: per-word confidence, reading order and sentence splitting
 *
 * Nothing here touches Vision, audio or the UI, so every rule is unit-tested (ReadAloudTests).
 * Geometry is in image pixels with the origin at the TOP-LEFT, in the wearer's point of view:
 * the glasses camera looks where the wearer looks, so x grows towards the wearer's right (see
 * ReadFraming for why that matters for guidance). TextRecognizer converts Vision's bottom-left
 * normalized boxes into this.
 */

import CoreGraphics
import Foundation

/// One word and how sure the recognizer was of it, 0...1.
struct ReadWord: Equatable, Sendable {
  var text: String
  var confidence: Float
}

/// One recognized line of text.
struct ReadLine: Equatable, Sendable {
  var words: [ReadWord]
  /// Pixels, top-left origin, wearer's point of view.
  var box: CGRect

  var text: String { words.map(\.text).joined(separator: " ") }
}

/// Everything recognized in one image.
struct ReadPage: Equatable, Sendable {
  var lines: [ReadLine]
  /// Pixel size of the image the boxes refer to (after orientation).
  var imageSize: CGSize
}

// MARK: - Word confidence

/// Vision gives one confidence per line, not per word. Per-word doubt comes from the alternative
/// candidates instead: a word the runners-up spell differently is a word the recognizer wasn't
/// sure of. That catches the cases that matter most ("5" vs "8", "rn" vs "m") without flagging a
/// whole line because one word was hard.
///
/// On clean print `.accurate` still returns runners-up, at the same confidence as the top line,
/// that only move a space or lose a letter: "brownfox", "brown fo", "jump", "tst", "age."
/// (captured from the mock's stream frame, see testVisionRunnersUpOnCleanPrintAreNotDoubt). They
/// offer no competing reading, so they aren't doubt, or every clean line would get the "uncertain"
/// earcon. A runner-up that changes a letter or adds one still counts. Numbers, units and "not"
/// are always compared strictly, because there a lost character changes the meaning.
enum WordConfidence {
  /// An alternative only counts if it is at least this close to the top candidate's confidence.
  static let alternativeWeight: Float = 0.5
  /// A disputed word keeps this share of the line's confidence (lands below the uncertain
  /// threshold for any line confidence).
  static let disputedFactor: Float = 0.45

  static func words(top: String, confidence: Float, alternatives: [(text: String, confidence: Float)]) -> [ReadWord] {
    let topTokens = tokenize(top)
    var disputed = Array(repeating: false, count: topTokens.count)
    for alternative in alternatives where alternative.confidence >= confidence * alternativeWeight && alternative.confidence > 0 {
      let altTokens = tokenize(alternative.text)
      // Same characters with the spaces elsewhere: only strictly compared words can be disputed.
      let spacingOnly = altTokens.joined() == topTokens.joined()
      if altTokens.count == topTokens.count {
        for index in topTokens.indices where normalized(topTokens[index]) != normalized(altTokens[index]) {
          let strict = isStrict(topTokens[index])
          if strict || !(spacingOnly || isOneLetterLost(normalized(topTokens[index]), in: normalized(altTokens[index]))) {
            disputed[index] = true
          }
        }
      } else {
        // Different word count: no reliable alignment, so a word is disputed if it doesn't
        // appear in the alternative at all.
        var pool = altTokens.map(normalized)
        for index in topTokens.indices {
          if let match = pool.firstIndex(of: normalized(topTokens[index])) {
            pool.remove(at: match)
          } else if !spacingOnly || isStrict(topTokens[index]) {
            disputed[index] = true
          }
        }
      }
    }
    return topTokens.enumerated().map { index, token in
      ReadWord(text: token, confidence: disputed[index] ? confidence * disputedFactor : confidence)
    }
  }

  static func tokenize(_ text: String) -> [String] {
    text.split(whereSeparator: \.isWhitespace).map(String.init)
  }

  /// Words where one character changes the meaning: numbers, dose and money units, "not".
  static func isStrict(_ token: String) -> Bool {
    guard !token.contains(where: \.isNumber) else { return true }
    let word = normalized(token).lowercased()
    return word == "not" || ReadSpeech.isDoseUnit(word) || ReadSpeech.currencyWords.contains(word)
      || ReadSpeech.numberWords.contains(word)
  }

  /// True when `alternative` is `top`, a word of letters, with exactly one letter missing.
  static func isOneLetterLost(_ top: String, in alternative: String) -> Bool {
    guard top.count == alternative.count + 1, top.allSatisfy(\.isLetter) else { return false }
    let lost = zip(top, alternative).prefix { $0 == $1 }.count
    return top.prefix(lost) + top.dropFirst(lost + 1) == alternative
  }

  /// Compares words without the punctuation around them ("dog." vs "dog,"), but keeps the
  /// punctuation inside ("2.5" vs "25" stays a disagreement).
  static func normalized(_ token: String) -> String {
    token.trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "$€£¥₹%")))
  }
}

// MARK: - Reading order

enum ReadingOrder {
  /// Lines on the same row that Vision split apart (a wide gap, a label and its value) are
  /// merged back when the gap is at most this many line heights. Kept small so the two columns
  /// of a page, which also share rows, stay apart.
  static let rowMergeGap: CGFloat = 1.0
  /// A line joins the block above it when the vertical gap is at most this many line heights.
  static let blockGap: CGFloat = 1.2
  /// ...and when it overlaps that block horizontally by at least this share of the narrower one.
  static let blockOverlap: CGFloat = 0.3

  /// Lines grouped into blocks (paragraphs, columns), blocks in reading order, lines in each
  /// block top to bottom.
  static func blocks(_ lines: [ReadLine]) -> [[ReadLine]] {
    let rows = mergeRows(lines.filter { !$0.words.isEmpty })
    return orderBlocks(groupBlocks(rows))
  }

  static func mergeRows(_ lines: [ReadLine]) -> [ReadLine] {
    var merged: [ReadLine] = []
    for line in lines.sorted(by: topThenLeft) {
      if let index = merged.firstIndex(where: { sameRow($0, line) }) {
        let row = merged[index]
        let (left, right) = row.box.minX <= line.box.minX ? (row, line) : (line, row)
        merged[index] = ReadLine(words: left.words + right.words, box: row.box.union(line.box))
      } else {
        merged.append(line)
      }
    }
    return merged
  }

  private static func sameRow(_ a: ReadLine, _ b: ReadLine) -> Bool {
    let height = min(a.box.height, b.box.height)
    guard height > 0 else { return false }
    let verticalOverlap = min(a.box.maxY, b.box.maxY) - max(a.box.minY, b.box.minY)
    guard verticalOverlap >= 0.5 * height else { return false }
    let gap = max(a.box.minX, b.box.minX) - min(a.box.maxX, b.box.maxX)
    return gap >= -0.2 * height && gap <= rowMergeGap * max(a.box.height, b.box.height)
  }

  static func groupBlocks(_ lines: [ReadLine]) -> [[ReadLine]] {
    var blocks: [[ReadLine]] = []
    for line in lines.sorted(by: topThenLeft) {
      let target = blocks.lastIndex { block in
        guard let last = block.last else { return false }
        let narrower = min(last.box.width, line.box.width)
        let overlap = min(last.box.maxX, line.box.maxX) - max(last.box.minX, line.box.minX)
        let lineHeight = max(1, min(last.box.height, line.box.height))
        let gap = line.box.minY - last.box.maxY
        return overlap >= blockOverlap * narrower && gap <= blockGap * lineHeight && gap >= -0.5 * lineHeight
      }
      if let target {
        blocks[target].append(line)
      } else {
        blocks.append([line])
      }
    }
    return blocks
  }

  /// Top to bottom, except that a block sitting beside the current topmost one (it starts before
  /// that block ends and doesn't overlap it horizontally) and further left is read first. That
  /// reads two columns left then right, and a heading above them first.
  static func orderBlocks(_ blocks: [[ReadLine]]) -> [[ReadLine]] {
    var remaining = blocks.sorted { bounds($0).minY < bounds($1).minY }
    var ordered: [[ReadLine]] = []
    while let top = remaining.first {
      let topBounds = bounds(top)
      var pick = 0
      for index in remaining.indices.dropFirst() {
        let candidate = bounds(remaining[index])
        guard candidate.minY < topBounds.maxY else { break }
        let besideTop = min(candidate.maxX, topBounds.maxX) - max(candidate.minX, topBounds.minX) <= 0
        if besideTop, candidate.minX < bounds(remaining[pick]).minX {
          pick = index
        }
      }
      ordered.append(remaining.remove(at: pick))
    }
    return ordered
  }

  static func bounds(_ block: [ReadLine]) -> CGRect {
    block.dropFirst().reduce(block.first?.box ?? .zero) { $0.union($1.box) }
  }

  private static func topThenLeft(_ a: ReadLine, _ b: ReadLine) -> Bool {
    a.box.minY != b.box.minY ? a.box.minY < b.box.minY : a.box.minX < b.box.minX
  }
}

// MARK: - Sentences

enum SentenceSplitter {
  /// A sentence longer than this is cut, so next/previous stays useful on unpunctuated text.
  static let maxWords = 40
  /// A line without end punctuation, narrower than this share of its block and followed by a
  /// capitalised line, is its own unit: headings, list items, menu lines, label rows.
  static let shortLineShare: CGFloat = 0.7

  static let abbreviations: Set<String> = [
    "mr.", "mrs.", "ms.", "dr.", "prof.", "st.", "vs.", "no.", "fig.", "approx.", "e.g.", "i.e.", "jr.", "sr.", "mt.",
    "dept.", "tel.", "ref.", "vol.", "p.", "pp.",
  ]

  /// Blocks (in reading order) to sentences of words. Rejoins words hyphenated across lines,
  /// and always ends a sentence at the end of a block.
  static func sentences(blocks: [[ReadLine]]) -> [[ReadWord]] {
    var sentences: [[ReadWord]] = []
    for block in blocks {
      let (words, hardBreaks) = joinLines(block)
      var current: [ReadWord] = []
      for (index, word) in words.enumerated() {
        current.append(word)
        let next = index + 1 < words.count ? words[index + 1] : nil
        if next == nil || hardBreaks.contains(index) || endsSentence(word.text, next: next?.text) || current.count >= maxWords {
          sentences.append(current)
          current = []
        }
      }
    }
    return sentences
  }

  /// The block's words in order, and the indices after which a line-level break falls.
  static func joinLines(_ block: [ReadLine]) -> (words: [ReadWord], hardBreaks: Set<Int>) {
    let blockWidth = ReadingOrder.bounds(block).width
    var words: [ReadWord] = []
    var hardBreaks: Set<Int> = []
    for (lineIndex, line) in block.enumerated() {
      var lineWords = line.words
      if let last = words.last, let first = lineWords.first, isHyphenBreak(last.text, then: first.text) {
        words[words.count - 1] = ReadWord(
          text: String(last.text.dropLast()) + first.text, confidence: min(last.confidence, first.confidence))
        lineWords.removeFirst()
      }
      words.append(contentsOf: lineWords)
      if lineIndex + 1 < block.count, let last = words.last {
        let nextLine = block[lineIndex + 1]
        let startsUpper = nextLine.words.first?.text.first.map { $0.isUppercase || $0.isNumber } ?? false
        let hasEndPunctuation = last.text.last.map { ".!?:;,".contains($0) } ?? false
        if !hasEndPunctuation, startsUpper, line.box.width < shortLineShare * blockWidth {
          hardBreaks.insert(words.count - 1)
        }
      }
    }
    return (words, hardBreaks)
  }

  /// "medi-" + "cation" → "medication". Only when the next line starts lower case, so a real
  /// hyphenated name ("Lloyd-" / "George") or a dash isn't glued.
  static func isHyphenBreak(_ word: String, then next: String) -> Bool {
    guard word.count > 1, word.hasSuffix("-"), !word.hasSuffix("--"),
      let previous = word.dropLast().last, previous.isLetter,
      let first = next.first, first.isLowercase
    else { return false }
    return true
  }

  static func endsSentence(_ word: String, next: String?) -> Bool {
    let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: ")]}\"'”’»"))
    guard let last = trimmed.last, ".!?…".contains(last) else { return false }
    if let next, let first = next.first, first.isLowercase { return false }
    guard last == "." else { return true }
    let lower = trimmed.lowercased()
    if abbreviations.contains(lower) { return false }
    // An initial: "J. R. R. Tolkien".
    if trimmed.count == 2, trimmed.first?.isUppercase == true { return false }
    return true
  }
}
