/*
 * StepSplitter - the steps of a recipe or a manual, as printed ("Read me the next step", V2)
 *
 * Pure: text in, steps out, so any tool can reuse it (Labels' cooking steps, Mail, a book).
 * Text is lines separated by newlines; a blank line separates blocks (TextReader writes the page
 * that way, see StepPageText).
 *
 * Rules:
 * - A step starts at a marker at the start of a line: "Step 1", "1.", "1)", "1:", "a)", "(a)", or a
 *   bullet ("•", "-", "*", "▪", "◦", "●", "·"). A number alone on a line ("1" or "1.") starts a
 *   step whose words are on the next line. "1.5 cups" and "10:30" are not markers: a marker is
 *   followed by a space.
 * - Lines after a marker line carry on the same step, up to the next marker, a blank line or a
 *   heading.
 * - A "Method", "Instructions", "Directions", "Steps", "How to use"... heading limits the search to
 *   what follows it, up to the next heading such as "Notes" or "Nutrition". Under such a heading
 *   with no markers, each paragraph is a step, and a single paragraph is split into sentences.
 * - "Ingredients", "You will need" and the like are never steps, so a bulleted ingredient list
 *   above numbered steps doesn't count.
 * - Numbered markers win over bullets. Bullets count only when there are no numbered markers.
 * - Two numbered steps run together on one line ("1. Mix. 2. Bake.") are split when the second
 *   number follows the first.
 * - Fewer than two steps, and no heading: no steps. Ordinary prose is not a recipe.
 *
 * Steps keep their printed words and markers. Line breaks inside a step become spaces, and a word
 * hyphenated across lines is joined ("medi-" + "cation").
 */

import Foundation

enum StepSplitter {
  /// The steps in `text`, in order, as printed. Empty when the text doesn't look like steps.
  static func steps(in text: String) -> [String] {
    let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
    let (region, hasHeading) = searchRegion(lines)
    let candidates = region.map { lines[$0] }
    let markers = candidates.map(marker)
    let numbered = markers.filter { $0?.isNumbered == true }.count
    let bullets = markers.filter { $0 == .bullet }.count

    var steps: [String]
    if numbered >= 2 || (hasHeading && numbered >= 1) {
      steps = collect(candidates, markers: markers) { $0.isNumbered }
      steps = steps.flatMap(splitInline)
    } else if bullets >= 2 || (hasHeading && bullets >= 1) {
      steps = collect(candidates, markers: markers) { $0 == .bullet }
    } else if hasHeading {
      steps = paragraphs(candidates)
    } else {
      steps = []
    }
    steps = steps.filter { !isMarkerOnly($0) }
    return steps.count >= 2 || (hasHeading && !steps.isEmpty) ? steps : []
  }

  // MARK: Markers

  enum Marker: Equatable {
    case number(Int)
    case letter
    case bullet

    var isNumbered: Bool { self != .bullet }
  }

  /// The marker at the start of `line`, if any.
  static func marker(_ line: String) -> Marker? {
    let range = NSRange(line.startIndex..., in: line)
    if let match = stepWord.firstMatch(in: line, range: range), let number = Int(capture(1, match, line) ?? "") {
      return .number(number)
    }
    if let match = numberMark.firstMatch(in: line, range: range), let number = Int(capture(1, match, line) ?? "") {
      return .number(number)
    }
    if let match = numberAlone.firstMatch(in: line, range: range), let number = Int(capture(1, match, line) ?? "") {
      return .number(number)
    }
    if letterMark.firstMatch(in: line, range: range) != nil { return .letter }
    if bulletMark.firstMatch(in: line, range: range) != nil { return .bullet }
    return nil
  }

  /// "Step 3", "Step 3:", "STEP 3." then a space (or the end of the line).
  private static let stepWord = regex(#"^step\s*(\d{1,2})\b\s*[:.)\-–]?(\s+|$)"#)
  /// "3." "3)" "3:" then a space.
  private static let numberMark = regex(#"^(\d{1,2})\s?[.):]\s+\S"#)
  /// A number alone on its line ("3" or "3."), words on the next line.
  private static let numberAlone = regex(#"^(\d{1,2})[.)]?$"#)
  /// "a)" "(a)" "b." then a space. Lower case only, so "A. Smith" isn't a step.
  private static let letterMark = regex(#"^(\([a-z]\)|[a-z]\))\s+\S"#, caseInsensitive: false)
  /// A bullet glyph, then the step's words.
  private static let bulletMark = regex(#"^([•·▪◦●‣∙]\s*\S|[-*–]\s+\S)"#)

  // MARK: Headings

  private static let methodHeadings = regex(
    #"^(method|methods|instructions|directions|preparation|prep|steps|step by step|step-by-step|how to make( it)?|how to cook( it)?|how to use( it)?|how to|cooking instructions|cooking method|to make|to cook|assembly( instructions)?|installation|install|setup|set up|getting started|procedure|what to do|usage)\s*[:\-–]?$"#)
  private static let otherHeadings = regex(
    #"^(ingredients|ingredient list|you will need|you'll need|youll need|what you need|what you'll need|equipment|tools( needed)?|notes?|tips?|cook'?s notes?|nutrition.*|nutritional information|serves\s*\d.*|makes\s*(about\s*)?\d.*|yield\s*:.*|storage|to store|warnings?|caution|safety( information)?|in the box|what'?s in the box|contents|parts( list)?|specifications?|troubleshooting|warranty)\s*[:\-–]?$"#)

  static func isMethodHeading(_ line: String) -> Bool {
    methodHeadings.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
  }

  static func isOtherHeading(_ line: String) -> Bool {
    otherHeadings.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
  }

  /// "Ingredients" and the like: a list that is never steps.
  private static func isListHeading(_ line: String) -> Bool {
    let lower = line.lowercased()
    return ["ingredient", "you will need", "you'll need", "youll need", "what you need", "what you'll need", "equipment",
      "tools", "in the box", "contents", "parts"].contains { lower.hasPrefix($0) } && isOtherHeading(line)
  }

  /// The line numbers to look in, and whether a method heading chose them.
  static func searchRegion(_ lines: [String]) -> (lines: [Int], hasHeading: Bool) {
    if let heading = lines.firstIndex(where: isMethodHeading) {
      var region: [Int] = []
      for index in lines.indices.dropFirst(heading + 1) {
        if isOtherHeading(lines[index]) { break }
        region.append(index)
      }
      return (region, true)
    }
    // No method heading: everything except an ingredients-style list. That list runs from its
    // heading to the next heading, or to the first numbered step. Headings stay in, as breaks.
    var region: [Int] = []
    var inList = false
    for (index, line) in lines.enumerated() {
      if isListHeading(line) {
        inList = true
        region.append(index)
        continue
      }
      if inList {
        if isOtherHeading(line) {
          inList = false
        } else if let mark = marker(line), mark.isNumbered {
          inList = false
        } else {
          continue
        }
      }
      region.append(index)
    }
    return (region, false)
  }

  // MARK: Building steps

  private static func collect(_ lines: [String], markers: [Marker?], starts: (Marker) -> Bool) -> [String] {
    var steps: [String] = []
    var current: [String]?
    for (line, mark) in zip(lines, markers) {
      if let mark, starts(mark) {
        if let current { steps.append(join(current)) }
        current = [line]
      } else if isMethodHeading(line) || isOtherHeading(line) {
        // A heading always ends the step: what follows it isn't part of it.
        if let done = current { steps.append(join(done)) }
        current = nil
      } else if line.isEmpty {
        // A blank line ends a step, unless only its number has been seen ("3" then the words).
        if let done = current, !isMarkerOnly(done.joined(separator: " ")) {
          steps.append(join(done))
          current = nil
        }
      } else if current != nil {
        current?.append(line)
      }
    }
    if let current { steps.append(join(current)) }
    return steps
  }

  /// Under a method heading with no markers: one step per paragraph, or per sentence when it is
  /// all one paragraph.
  private static func paragraphs(_ lines: [String]) -> [String] {
    var paragraphs: [[String]] = [[]]
    for line in lines {
      if line.isEmpty {
        if !(paragraphs.last?.isEmpty ?? true) { paragraphs.append([]) }
      } else {
        paragraphs[paragraphs.count - 1].append(line)
      }
    }
    let texts = paragraphs.filter { !$0.isEmpty }.map(join)
    guard texts.count == 1, let only = texts.first else { return texts }
    return sentences(only)
  }

  /// "Heat the oil. Add the onions." → two. Ends at . ! ? followed by a space and a capital or a
  /// digit, but not after a short abbreviation ("approx.", "e.g.").
  static func sentences(_ text: String) -> [String] {
    let words = text.split(separator: " ").map(String.init)
    var result: [String] = []
    var current: [String] = []
    for (index, word) in words.enumerated() {
      current.append(word)
      let next = index + 1 < words.count ? words[index + 1] : nil
      if next == nil || SentenceSplitter.endsSentence(word, next: next) {
        result.append(current.joined(separator: " "))
        current = []
      }
    }
    return result
  }

  /// "1. Mix the flour. 2. Add the eggs." → two steps, when each number follows the one before.
  static func splitInline(_ step: String) -> [String] {
    guard case .number(var expected)? = marker(step) else { return [step] }
    let words = step.split(separator: " ").map(String.init)
    var pieces: [String] = []
    var current: [String] = []
    for (index, word) in words.enumerated() {
      let afterSentence = current.last?.last.map { ".!?".contains($0) } ?? false
      let isNext = index > 0 && index + 1 < words.count && afterSentence
        && (word == "\(expected + 1)." || word == "\(expected + 1))")
      if isNext {
        pieces.append(current.joined(separator: " "))
        current = []
        expected += 1
      }
      current.append(word)
    }
    if !current.isEmpty { pieces.append(current.joined(separator: " ")) }
    return pieces
  }

  /// Lines joined with spaces; a word hyphenated at a line end is joined to the next line's first.
  static func join(_ lines: [String]) -> String {
    var text = ""
    for line in lines where !line.isEmpty {
      if text.isEmpty {
        text = line
      } else if let last = text.split(separator: " ").last, let first = line.split(separator: " ").first,
        SentenceSplitter.isHyphenBreak(String(last), then: String(first))
      {
        text = String(text.dropLast()) + line
      } else {
        text += " " + line
      }
    }
    return text
  }

  /// A marker with no words ("3." waiting for a line that never came).
  private static func isMarkerOnly(_ step: String) -> Bool {
    let text = step.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return true }
    let range = NSRange(text.startIndex..., in: text)
    if numberAlone.firstMatch(in: text, range: range) != nil { return true }
    if let match = stepWord.firstMatch(in: text, range: range), match.range.upperBound == range.upperBound { return true }
    return false
  }

  /// The words of a step to speak: a leading bullet glyph is dropped (it isn't a word); numbers,
  /// letters and "Step 3" stay, as printed.
  static func spokenText(_ step: String) -> String {
    var text = Substring(step)
    if let first = text.first, "•·▪◦●‣∙-*–".contains(first) {
      text = text.dropFirst()
    }
    return text.trimmingCharacters(in: .whitespaces)
  }

  /// True when the step is printed with a number, letter or "Step N" (so its place is heard).
  static func isNumberedInPrint(_ step: String) -> Bool {
    marker(step)?.isNumbered ?? false
  }

  // MARK: Regex helpers

  private static func regex(_ pattern: String, caseInsensitive: Bool = true) -> NSRegularExpression {
    // swiftlint:disable:next force_try
    try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
  }

  private static func capture(_ group: Int, _ match: NSTextCheckingResult, _ text: String) -> String? {
    guard let range = Range(match.range(at: group), in: text) else { return nil }
    return String(text[range])
  }
}

// MARK: - The page as text, for the splitter

/// A read page as StepSplitter wants it, with the words (and their confidence) in the same order,
/// so a step's words can be matched back to how sure the recognizer was of them.
enum StepPageText {
  /// Lines as words joined by spaces, lines by newlines, blocks by a blank line.
  static func make(blocks: [[ReadLine]]) -> (text: String, words: [ReadWord]) {
    let text = blocks.map { block in block.map(\.text).joined(separator: "\n") }.joined(separator: "\n\n")
    return (text, blocks.flatMap { $0.flatMap(\.words) })
  }

  /// A step's words with their confidence, matched in order from `cursor` in the page's words.
  /// A word hyphenated across lines matches the two halves. A word not found (it shouldn't happen)
  /// gets a confidence just below the money and dose threshold, so a number in it is never read on
  /// trust.
  static func words(of step: String, in page: [ReadWord], cursor: inout Int) -> [ReadWord] {
    let tokens = step.split(whereSeparator: \.isWhitespace).map(String.init)
    var result: [ReadWord] = []
    for token in tokens {
      var found: ReadWord?
      var search = cursor
      while search < page.count, search < cursor + 40 {
        let word = page[search]
        if word.text == token {
          found = word
          cursor = search + 1
          break
        }
        if search + 1 < page.count, word.text.hasSuffix("-"), String(word.text.dropLast()) + page[search + 1].text == token {
          found = ReadWord(text: token, confidence: min(word.confidence, page[search + 1].confidence))
          cursor = search + 2
          break
        }
        search += 1
      }
      result.append(found ?? ReadWord(text: token, confidence: ReadSpeech.sensitiveNumberBelow - 0.01))
    }
    return result
  }
}

// MARK: - Where the user is in the steps

/// Next, previous, repeat and "where am I" over a fixed list of steps. Pure.
struct StepNavigator: Equatable {
  let count: Int
  /// nil before the first step is heard.
  private(set) var index: Int?

  enum Move: Equatable {
    /// Say step `n` (0-based).
    case step(Int)
    /// Asked for the next step after the last; stays on the last.
    case pastLast
    /// Asked for the previous step on the first; says the first again.
    case atFirst
    case noSteps
  }

  init(count: Int, index: Int? = nil) {
    self.count = count
    self.index = index
  }

  mutating func next() -> Move {
    guard count > 0 else { return .noSteps }
    guard let index else {
      self.index = 0
      return .step(0)
    }
    guard index + 1 < count else { return .pastLast }
    self.index = index + 1
    return .step(index + 1)
  }

  mutating func previous() -> Move {
    guard count > 0 else { return .noSteps }
    guard let index, index > 0 else {
      self.index = 0
      return .atFirst
    }
    self.index = index - 1
    return .step(index - 1)
  }

  mutating func repeatStep() -> Move {
    guard count > 0 else { return .noSteps }
    let at = index ?? 0
    index = at
    return .step(at)
  }

  /// Step `number` as people count (1-based).
  mutating func go(to number: Int) -> Move {
    guard count > 0 else { return .noSteps }
    let at = min(max(number, 1), count) - 1
    index = at
    return .step(at)
  }

  /// Steps after the current one.
  var remaining: Int { count - ((index ?? -1) + 1) }
}
