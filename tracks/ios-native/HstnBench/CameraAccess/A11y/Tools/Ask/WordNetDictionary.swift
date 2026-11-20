/*
 * WordNetDictionary - the bundled WordNet 3.0 definitions, looked up on the phone with no network
 *
 * wordnet.wnask (next to this file, copied into the app bundle) is the same file the Android app
 * ships, built by tracks/android-native/HstnBench/scripts/build_ask_dictionary.py from Princeton
 * WordNet 3.0: 117,659 definitions, 147,306 lemmas in WordNet's sense order, 5,947 irregular forms.
 * 3.46 MB gzip'd, about 10 MB unpacked. The WordNet licence is the file's '#' header (it must stay
 * with every copy) and is quoted in notes/watch-and-ask-ios.md.
 *
 * Format (text, UTF-8): "#WNASK 1", '#' licence lines, then three sections:
 *   @S <n>  one definition per line, line number = synset id
 *   @L <n>  "lemma\tpos ids;pos ids" sorted by bytes; ids base 36, comma separated
 *   @X <n>  "form\tpos\tbase,base" irregular forms
 * Loading is one pass: gunzip, then line offsets for the two big sections (memchr), so there are
 * no per-entry objects; a lookup is a binary search over the lemma lines. Loaded lazily, off the
 * main actor, the first time Ask is opened (AskDictionaryLoader). Inflections and spellings are
 * AskLemmatiser's job; this only knows exact lemmas. Ported from Android's tools/ask/Dictionary.kt.
 */

import Compression
import Foundation

final class WordNetDictionary: Sendable {
  /// One meaning. `pos` is n (noun), v (verb), a (adjective) or r (adverb).
  struct Sense: Equatable, Sendable {
    var pos: Character
    var gloss: String
  }

  /// A lemma and its senses grouped by part of speech, in WordNet's order (most common first).
  struct Entry: Equatable, Sendable {
    var lemma: String
    var groups: [(pos: Character, ids: [Int])]

    var parts: [Character] { groups.map(\.pos) }

    func senseCount(_ pos: Character) -> Int { groups.first { $0.pos == pos }?.ids.count ?? 0 }

    static func == (lhs: Entry, rhs: Entry) -> Bool {
      lhs.lemma == rhs.lemma && lhs.groups.map(\.pos) == rhs.groups.map(\.pos) && lhs.groups.map(\.ids) == rhs.groups.map(\.ids)
    }
  }

  enum LoadError: Error, Equatable {
    case missing
    case notGzip
    case corrupt
    case badFormat(String)
  }

  static let resourceName = "wordnet"
  static let resourceExtension = "wnask"

  private let data: [UInt8]
  private let glossStart: [Int32]
  private let lemmaStart: [Int32]
  private let exceptions: [String: [Irregular]]

  struct Irregular: Equatable, Sendable {
    var pos: Character
    var base: String
  }

  var lemmaCount: Int { lemmaStart.count }
  var definitionCount: Int { glossStart.count }

  private init(data: [UInt8], glossStart: [Int32], lemmaStart: [Int32], exceptions: [String: [Irregular]]) {
    self.data = data
    self.glossStart = glossStart
    self.lemmaStart = lemmaStart
    self.exceptions = exceptions
  }

  // MARK: Lookups

  /// The definition for synset `id`.
  func gloss(_ id: Int) -> String {
    guard id >= 0, id < glossStart.count else { return "" }
    let start = Int(glossStart[id])
    return string(from: start, to: lineEnd(start))
  }

  /// The entry for `lemma` exactly (lower case, spaces between words), or nil.
  func entry(_ lemma: String) -> Entry? {
    let lower = lemma.lowercased()
    let key = Array(lower.utf8)
    guard !key.isEmpty, let line = find(key) else { return nil }
    let tab = line + key.count
    let body = string(from: tab + 1, to: lineEnd(tab))
    let groups: [(pos: Character, ids: [Int])] = body.split(separator: ";").compactMap { group in
      guard group.count >= 2, let pos = group.first else { return nil }
      let ids = group.dropFirst().split(separator: ",").compactMap { Int($0, radix: 36) }
      return (pos, ids)
    }
    return Entry(lemma: lower, groups: groups)
  }

  func contains(_ lemma: String) -> Bool {
    let key = Array(lemma.lowercased().utf8)
    return !key.isEmpty && find(key) != nil
  }

  /// All senses of `entry`, parts of speech in `posOrder` (default WordNet's), senses in order.
  func senses(_ entry: Entry, posOrder: [Character]? = nil) -> [Sense] {
    (posOrder ?? entry.parts).flatMap { pos in
      (entry.groups.first { $0.pos == pos }?.ids ?? []).map { Sense(pos: pos, gloss: gloss($0)) }
    }
  }

  /// Irregular forms: "mice" gives (n, mouse), "went" gives (v, go).
  func irregular(_ form: String) -> [Irregular] {
    exceptions[form.lowercased()] ?? []
  }

  // MARK: Internals

  private static let newline = UInt8(ascii: "\n")
  private static let tab = UInt8(ascii: "\t")

  private func lineEnd(_ from: Int) -> Int {
    data.withUnsafeBufferPointer { Self.lineEnd(in: $0, from: from) }
  }

  private static func lineEnd(in buffer: UnsafeBufferPointer<UInt8>, from: Int) -> Int {
    guard from < buffer.count, let base = buffer.baseAddress else { return buffer.count }
    guard let found = memchr(base + from, Int32(newline), buffer.count - from) else { return buffer.count }
    return base.distance(to: found.assumingMemoryBound(to: UInt8.self))
  }

  private func string(from start: Int, to end: Int) -> String {
    guard start < end, end <= data.count else { return "" }
    return String(decoding: data[start..<end], as: UTF8.self)
  }

  /// Start of the lemma line whose key is exactly `key`.
  private func find(_ key: [UInt8]) -> Int? {
    data.withUnsafeBufferPointer { buffer -> Int? in
      var low = 0
      var high = lemmaStart.count - 1
      while low <= high {
        let middle = (low + high) / 2
        let line = Int(lemmaStart[middle])
        let order = Self.compare(buffer, line: line, key: key)
        if order < 0 {
          low = middle + 1
        } else if order > 0 {
          high = middle - 1
        } else {
          return line
        }
      }
      return nil
    }
  }

  /// The lemma at `line` (up to its tab) against `key`, as unsigned bytes.
  private static func compare(_ buffer: UnsafeBufferPointer<UInt8>, line: Int, key: [UInt8]) -> Int {
    var i = 0
    while true {
      let byte = line + i < buffer.count ? buffer[line + i] : tab
      let lineDone = byte == tab || byte == newline
      let keyDone = i == key.count
      if lineDone, keyDone { return 0 }
      if lineDone { return -1 }
      if keyDone { return 1 }
      let difference = Int(byte) - Int(key[i])
      if difference != 0 { return difference }
      i += 1
    }
  }

  // MARK: Loading

  /// The copy in the app bundle.
  static func loadBundled(bundle: Bundle = .main) throws -> WordNetDictionary {
    guard let url = bundle.url(forResource: resourceName, withExtension: resourceExtension) else { throw LoadError.missing }
    return try load(gzipData: Data(contentsOf: url, options: .mappedIfSafe))
  }

  static func load(gzipData: Data) throws -> WordNetDictionary {
    try parse(Array(gunzip(gzipData)))
  }

  /// A single-member gzip file's contents (RFC 1952 header, raw DEFLATE, trailer).
  static func gunzip(_ gzip: Data) throws -> Data {
    let bytes = [UInt8](gzip)
    guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { throw LoadError.notGzip }
    let flags = bytes[3]
    var offset = 10
    if flags & 0x04 != 0 {
      guard offset + 2 <= bytes.count else { throw LoadError.corrupt }
      offset += 2 + Int(bytes[offset]) + Int(bytes[offset + 1]) << 8
    }
    if flags & 0x08 != 0 {
      while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
      offset += 1
    }
    if flags & 0x10 != 0 {
      while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
      offset += 1
    }
    if flags & 0x02 != 0 { offset += 2 }
    guard offset < bytes.count - 8 else { throw LoadError.corrupt }
    let n = bytes.count
    let expected = Int(bytes[n - 4]) | Int(bytes[n - 3]) << 8 | Int(bytes[n - 2]) << 16 | Int(bytes[n - 1]) << 24
    let deflated = Data(bytes[offset..<(n - 8)])
    // Apple's ZLIB algorithm is raw DEFLATE (RFC 1951), which is what gzip wraps.
    guard let inflated = try? (deflated as NSData).decompressed(using: .zlib) as Data else { throw LoadError.corrupt }
    // ISIZE is the length modulo 2^32.
    guard inflated.count & 0xFFFF_FFFF == expected else { throw LoadError.corrupt }
    return inflated
  }

  /// Parses the unpacked file.
  static func parse(_ data: [UInt8]) throws -> WordNetDictionary {
    let header = Array("#WNASK 1".utf8)
    guard data.count > header.count, Array(data[0..<header.count]) == header else { throw LoadError.badFormat("not WNASK 1") }
    var glosses: [Int32] = []
    var lemmas: [Int32] = []
    var exceptions: [String: [Irregular]] = [:]
    try data.withUnsafeBufferPointer { buffer in
      var position = 0
      func nextLine() -> Int {
        let start = position
        position = lineEnd(in: buffer, from: position) + 1
        return start
      }
      func text(_ start: Int) -> String {
        String(decoding: buffer[start..<lineEnd(in: buffer, from: start)], as: UTF8.self)
      }
      while position < buffer.count {
        let start = nextLine()
        if buffer[start] == UInt8(ascii: "#") || buffer[start] == newline { continue }
        let line = text(start)
        let parts = line.split(separator: " ")
        guard parts.count == 2, let count = Int(parts[1]) else { throw LoadError.badFormat(line) }
        switch parts[0] {
        case "@S":
          glosses.reserveCapacity(count)
          for _ in 0..<count { glosses.append(Int32(nextLine())) }
        case "@L":
          lemmas.reserveCapacity(count)
          for _ in 0..<count { lemmas.append(Int32(nextLine())) }
        case "@X":
          for _ in 0..<count {
            let fields = text(nextLine()).split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3, let pos = fields[1].first else { continue }
            for base in fields[2].split(separator: ",") {
              exceptions[String(fields[0]), default: []].append(Irregular(pos: pos, base: String(base)))
            }
          }
        default:
          throw LoadError.badFormat(line)
        }
      }
    }
    return WordNetDictionary(data: data, glossStart: glosses, lemmaStart: lemmas, exceptions: exceptions)
  }
}

/// Loads the bundled dictionary once, off the main actor, the first time something asks for it.
actor AskDictionaryLoader {
  static let shared = AskDictionaryLoader()

  private var task: Task<WordNetDictionary?, Never>?
  private let load: @Sendable () -> WordNetDictionary?

  init(load: @escaping @Sendable () -> WordNetDictionary? = { try? WordNetDictionary.loadBundled() }) {
    self.load = load
  }

  /// The dictionary, waiting for it if it's still loading; nil if it couldn't be loaded.
  func dictionary() async -> WordNetDictionary? {
    if let task { return await task.value }
    let load = load
    let started = DispatchTime.now().uptimeNanoseconds
    let newTask = Task.detached(priority: .userInitiated) { () -> WordNetDictionary? in
      let dictionary = load()
      let ms = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
      BenchClock.shared.record("ask_dictionary_load", ms: ms, detail: dictionary == nil ? "failed" : "ok")
      return dictionary
    }
    task = newTask
    return await newTask.value
  }

  /// Starts loading now, so the first question doesn't wait.
  nonisolated func warmUp() {
    Task { _ = await self.dictionary() }
  }
}
