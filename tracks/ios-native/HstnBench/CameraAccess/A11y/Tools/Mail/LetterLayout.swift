/*
 * LetterLayout - reading order for a letter page, from OCR line and block geometry
 *
 * Port of the Android LetterLayout.kt. A letter isn't a book page: a letterhead, two address
 * blocks side by side, a right-aligned date, a table of charges with labels on the left and
 * amounts on the right, then paragraphs and a signature. So:
 *   1. Table rows: an amount or a date (or a value after "Label:") on the right of the same row is
 *      joined to its label on the left: "Standing charge £12.30", so it's read as one line, not as
 *      a list of labels followed by a list of numbers.
 *   2. Stacked blocks merge (on iOS every Vision line starts as its own block).
 *   3. Blocks are read top to bottom; blocks side by side (two address blocks) left first.
 *   4. A block of short lines (an address) is read as one sentence with commas; a block of long
 *      lines is a paragraph, with words hyphenated across line ends rejoined.
 * Pure Swift.
 */

import CoreGraphics
import Foundation

/// Lines of one block, in order. `isShortLines` when it reads like an address.
struct LetterBlock: Equatable, Sendable {
  var lines: [LetterLine]
  var isShortLines: Bool

  var box: CGRect { lines.dropFirst().reduce(lines[0].box) { $0.union($1.box) } }
  var text: String { lines.map(\.text).joined(separator: "\n") }
}

struct LaidOutLetter: Equatable, Sendable {
  var scan: LetterScan
  var blocks: [LetterBlock]
  /// What "read it all" speaks, one entry per paragraph.
  var paragraphs: [String]
  /// Median line height on the page: the body text size.
  var bodyHeight: CGFloat

  var lines: [LetterLine] { blocks.flatMap(\.lines) }
}

enum LetterLayout {
  private static let dateLabel = MailRegex(
    "\\b(?:due|date|by|before|on|deadline|instalment|payment|appointment|expires?)\\s*:?\\s*$", ignoreCase: true)

  static func layout(_ scan: LetterScan) -> LaidOutLetter {
    let lines = scan.lines.filter { !$0.text.trimmed.isEmpty }
    guard !lines.isEmpty else { return LaidOutLetter(scan: scan, blocks: [], paragraphs: [], bodyHeight: 0) }
    let bodyHeight = median(lines.map(\.box.height))
    let joined = joinTableRows(lines)
    let textLeft = joined.map(\.box.minX).min() ?? 0
    let textRight = joined.map(\.box.maxX).max() ?? 0
    let textWidth = max(textRight - textLeft, 1)

    let groups = orderedGroups(joined, by: \.block).flatMap { splitAtGaps($0.stableSorted { $0.box.minY }, bodyHeight: bodyHeight) }
    let blocks = mergeStacked(groups, textWidth: textWidth).map { group in
      let short = group.filter { $0.box.width < textWidth * 0.55 }.count
      return LetterBlock(lines: group, isShortLines: group.count >= 2 && short * 10 >= group.count * 7)
    }
    let ordered = order(blocks)
    return LaidOutLetter(
      scan: scan, blocks: ordered, paragraphs: ordered.map(paragraph).filter { !$0.trimmed.isEmpty }, bodyHeight: bodyHeight)
  }

  /// The middle value (the lower middle for an even count), as Android's PageLayout.median.
  static func median(_ values: [CGFloat]) -> CGFloat {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[(sorted.count - 1) / 2]
  }

  /// Groups in order of each key's first appearance (Kotlin groupBy).
  private static func orderedGroups<Key: Hashable>(_ lines: [LetterLine], by key: (LetterLine) -> Key) -> [[LetterLine]] {
    var order: [Key] = []
    var groups: [Key: [LetterLine]] = [:]
    for line in lines {
      let k = key(line)
      if groups[k] == nil { order.append(k) }
      groups[k, default: []].append(line)
    }
    return order.map { groups[$0] ?? [] }
  }

  private static func isMoney(_ t: String) -> Bool {
    let m = LetterText.money(t)
    return !m.isEmpty && t.utf16Count - m.reduce(0) { $0 + $1.raw.utf16Count } <= 6
  }

  private static func isDate(_ t: String) -> Bool {
    let d = LetterText.dates(t)
    return d.count == 1 && t.utf16Count - d[0].raw.utf16Count <= 4
  }

  /// Joins a right-hand value (an amount, or anything after a "Label:") to its label on the same row.
  static func joinTableRows(_ lines: [LetterLine]) -> [LetterLine] {
    var out = lines
    for value in lines where isMoney(value.text.trimmed) || isDate(value.text.trimmed) {
      guard out.contains(value), let label = rowNeighbourOnLeft(out, of: value) else { continue }
      if !LetterText.money(label.text).isEmpty || !LetterText.dates(label.text).isEmpty { continue }
      // A date joins only a label that asks for one ("First instalment due"), never an address
      // line that happens to sit level with a right-aligned letter date.
      if !isMoney(value.text.trimmed) && !dateLabel.contains(label.text) { continue }
      merge(&out, label: label, value: value)
    }
    // "Account number:" | "1234 5678", "Payment due:" | "24 November 2026".
    for label in out {
      guard out.contains(label), label.text.trimmedEnd.hasSuffix(":"), let value = rowNeighbourOnRight(out, of: label) else {
        continue
      }
      merge(&out, label: label, value: value)
    }
    return out
  }

  private static func merge(_ out: inout [LetterLine], label: LetterLine, value: LetterLine) {
    guard let at = out.firstIndex(of: label) else { return }
    out[at] = LetterLine(
      text: label.text.trimmedEnd + " " + value.text.trimmed,
      box: label.box.union(value.box),
      block: label.block,
      confidence: [label.confidence, value.confidence].compactMap { $0 }.min(),
      words: !label.words.isEmpty && !value.words.isEmpty ? label.words + value.words : [])
    if let remove = out.firstIndex(of: value) { out.remove(at: remove) }
  }

  private static func sameRow(_ a: CGRect, _ b: CGRect) -> Bool {
    min(a.maxY, b.maxY) - max(a.minY, b.minY) >= 0.5 * min(a.height, b.height)
  }

  private static func rowNeighbourOnLeft(_ lines: [LetterLine], of line: LetterLine) -> LetterLine? {
    lines.filter { $0 != line && $0.box.maxX <= line.box.minX + 2 && sameRow($0.box, line.box) }
      .max { $0.box.maxX < $1.box.maxX }
  }

  private static func rowNeighbourOnRight(_ lines: [LetterLine], of line: LetterLine) -> LetterLine? {
    lines.filter { $0 != line && $0.box.minX >= line.box.maxX - 2 && sameRow($0.box, line.box) }
      .min { $0.box.minX < $1.box.minX }
  }

  /// A block with a big vertical gap inside it is two blocks.
  private static func splitAtGaps(_ lines: [LetterLine], bodyHeight: CGFloat) -> [[LetterLine]] {
    var out: [[LetterLine]] = []
    for line in lines {
      if let last = out.last?.last, line.box.minY - last.box.maxY <= bodyHeight * 1.2 {
        out[out.count - 1].append(line)
      } else {
        out.append([line])
      }
    }
    return out
  }

  /// Blocks stacked tightly (gap under ~0.9 of a line), aligned on the left (or, for short lines,
  /// on the right) and with the same text size are one block. Vision gives every line on its own,
  /// as ML Kit did for address lines and table labels on the Galaxy A26.
  static func mergeStacked(_ groups: [[LetterLine]], textWidth: CGFloat) -> [[LetterLine]] {
    var out = groups.stableSorted { $0[0].box.minY }
    var i = 0
    while i < out.count {
      let a = out[i]
      let aLast = a[a.count - 1].box
      let h = aLast.height
      let below = out.indices.dropFirst(i + 1).first { j in
        let b = out[j]
        let bFirst = b[0].box
        let gap = bFirst.minY - aLast.maxY
        // Loose: a line with descenders (g, y) has a taller box than one without.
        let sameSize = bFirst.height >= h * 0.6 && bFirst.height <= h * 1.67
        let left = abs((a.map(\.box.minX).min() ?? 0) - (b.map(\.box.minX).min() ?? 0)) <= h * 0.6
        let short = (a + b).allSatisfy { $0.box.width < textWidth * 0.55 }
        let right = short && abs((a.map(\.box.maxX).max() ?? 0) - (b.map(\.box.maxX).max() ?? 0)) <= h * 0.6
        return gap >= -2 && gap <= h * 0.9 && sameSize && (left || right)
      }
      if let below {
        out[i] += out[below]
        out.remove(at: below)
      } else {
        i += 1
      }
    }
    return out
  }

  /// Top to bottom; of blocks side by side (overlapping rows), the left one first.
  static func order(_ blocks: [LetterBlock]) -> [LetterBlock] {
    var rest = blocks
    var out: [LetterBlock] = []
    while !rest.isEmpty {
      var pick = rest.indices.min { rest[$0].box.minY < rest[$1].box.minY } ?? 0
      let pickBox = rest[pick].box
      let beside = rest.indices.filter { j in
        let b = rest[j].box
        return j != pick && b.maxX <= pickBox.minX + 4
          && min(b.maxY, pickBox.maxY) - max(b.minY, pickBox.minY) > 0.3 * min(b.height, pickBox.height)
      }
      if let left = beside.min(by: { rest[$0].box.minX < rest[$1].box.minX }) { pick = left }
      out.append(rest.remove(at: pick))
    }
    return out
  }

  /// One block as spoken text: an address with commas and a full stop, a paragraph rejoined.
  static func paragraph(_ block: LetterBlock) -> String {
    let texts = block.lines.map(\.text.trimmed).filter { !$0.isEmpty }
    guard !texts.isEmpty else { return "" }
    if block.isShortLines {
      let joined = texts.map { $0.trimmingTrailing([","]) }.joined(separator: ", ")
      return ".!?:".contains(joined.last ?? " ") ? joined : joined + "."
    }
    var out = ""
    for t in texts {
      // A table row ending in an amount or a date is its own sentence: "Standing charge £12.30."
      let length = t.utf16Count
      let endsInValue =
        (LetterText.money(t).last.map { $0.last >= length - 1 } ?? false)
        || (LetterText.dates(t).last.map { $0.last >= length - 1 } ?? false)
      // (Short lines only: a long body line can end in a date mid-sentence.)
      joinLine(&out, endsInValue && t.count <= 50 ? t + "." : t)
    }
    return out
  }

  private static let hyphens: Set<Character> = ["-", "\u{00AD}", "\u{2010}", "\u{2011}"]
  private static let dashes: Set<Character> = ["\u{2013}", "\u{2014}"]

  /// Appends `next`, rejoining a word hyphenated across the line end (Android PageLayout.joinLine,
  /// without its ML Kit-specific fragment repair).
  static func joinLine(_ out: inout String, _ next: String) {
    guard let nextFirst = next.first else { return }
    guard let last = out.last else {
      out = next
      return
    }
    let beforeLast = out.count >= 2 ? out[out.index(out.endIndex, offsetBy: -2)] : " "
    if hyphens.contains(last) && beforeLast.isLetter {
      out.removeLast()
      if nextFirst.isLowercase {
        // "exam-" + "ple" -> "example"
      } else {
        out.append("-")  // A soft hyphen before a capital: keep a plain hyphen.
      }
      out += next
    } else if dashes.contains(last) {
      out += next
    } else if last == "-" && beforeLast.isNumber && nextFirst.isNumber {
      out += next  // "12-14"
    } else {
      out += " " + next
    }
  }
}
