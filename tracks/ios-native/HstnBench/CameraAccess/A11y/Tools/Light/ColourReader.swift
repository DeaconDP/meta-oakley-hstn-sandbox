/*
 * ColourReader - "what colour is this?": names the thing in the middle of the view, honestly
 *
 * Port of Android's tools/light/ColourReader.kt (same thresholds, same tests). Input is a downscaled
 * camera frame as packed ARGB pixels. Steps:
 *  1. Centre patch: a square `patchFraction` of the frame's width, in the middle. Held at arm's
 *     length, that covers a mug or a folded shirt and not the room behind it.
 *  2. White balance from the surround (the outer frame, outside the middle `surroundX` of the width
 *     and `surroundY` of the height, so an object bigger than the patch doesn't leak in): the average
 *     of a grey-world estimate (the room averages to grey) and a white-patch estimate (the brightest
 *     things are white), in linear light. Applied at `wbStrength`, because the camera already
 *     balances white and grey-world is fooled by a coloured wall. The raw estimate's spread ("cast")
 *     says how tinted the light is, and is a reason to hedge.
 *  3. The patch's pixels, balanced, go to OKLab and are split in two with k-means (k = 2). If the
 *     smaller group is big enough and a different colour, it's two colours: "mostly white, with
 *     blue" (stripes, a pattern, a logo). Otherwise the main group is the colour.
 *  4. Naming: nearest everyday name (ColourPalette), with light/dark.
 *  5. Hedging: too dark or too much glare -> no colour at all; very dim light, a very strong cast, or
 *     a muted colour under a cast -> "hard to tell in this light, it might be..."; dim light, a cast,
 *     a muted colour, a colour between two families, a very dark and muted object, or a busy
 *     pattern -> "probably ...". A confident name needs decent, near-white light and a clear match.
 * ColourSpeech turns the result into the spoken sentence.
 */

import Foundation

enum ColourConfidence: Int, Comparable, Sendable {
  /// Say the name plainly.
  case confident
  /// "Probably ...".
  case probable
  /// "Hard to tell in this light. It might be ...".
  case unsure
  /// Don't name a colour ("Too dark to tell").
  case abstain

  static func < (a: ColourConfidence, b: ColourConfidence) -> Bool { a.rawValue < b.rawValue }
}

/// Why the answer is hedged; each has a short spoken explanation (ColourSpeech).
enum ColourHedgeReason: Sendable {
  case tooDark, glare, veryDim, dim, warmLight, coolLight, tintedLight, muted, between, darkObject, busyPattern
}

struct WhiteBalance: Equatable, Sendable {
  /// Gains applied to linear R, G, B (after strength).
  var gainR: Double
  var gainG: Double
  var gainB: Double
  /// Raw estimate's max gain / min gain: 1.0 = neutral light, 1.5 = clearly tinted.
  var cast: Double
  /// Raw blue gain / red gain: > 1 means the light is warm (yellow-orange).
  var warmth: Double

  static let none = WhiteBalance(gainR: 1, gainG: 1, gainB: 1, cast: 1, warmth: 1)
}

/// One colour found in the patch.
struct ColourPart: Equatable, Sendable {
  var match: ColourMatch
  var share: Double
  var swatch: UInt32
}

struct ColourResult: Equatable, Sendable {
  var confidence: ColourConfidence
  /// The main colour (nil when abstaining).
  var main: ColourPart?
  /// A second colour taking a good share of the patch, or nil.
  var second: ColourPart?
  var reasons: [ColourHedgeReason]
  var whiteBalance: WhiteBalance
  /// Frame brightness, mean luma 0...255.
  var frameLuma: Double
  /// Main colour's swatch for the screen (ARGB), grey when abstaining.
  var swatch: UInt32
}

enum ColourReader {
  /// Centre patch side as a fraction of the frame's width.
  static let patchFraction = 0.2
  /// The surround is outside the middle of the frame, this share of its width and height.
  static let surroundX = 0.6
  static let surroundY = 0.5
  /// How much of the estimated white-balance correction to apply.
  static let wbStrength = 0.75

  private static let clip = 250
  private static let maxGain = 2.0
  private static let minSecondShare = 0.22
  private static let minSecondDistance = 0.12

  static func read(_ pixels: [UInt32], width: Int, height: Int) -> ColourResult? {
    guard pixels.count == width * height, width >= 10, height >= 10 else { return nil }
    let side = max(4, Int(Double(width) * patchFraction))
    let cx = width / 2
    let cy = height / 2
    let x0 = cx - side / 2
    let y0 = cy - side / 2
    let mx = Int(Double(width) * surroundX / 2)
    let my = Int(Double(height) * surroundY / 2)

    let frameLumas = pixels.map(ColourSpace.luma)
    let frameMean = Double(frameLumas.reduce(0, +)) / Double(frameLumas.count)
    let frameP95 = percentile(frameLumas, 0.95)

    // Surround pixels for white balance.
    var surround: [UInt32] = []
    surround.reserveCapacity(pixels.count)
    for y in 0..<height {
      for x in 0..<width {
        if x >= cx - mx, x < cx + mx, y >= cy - my, y < cy + my { continue }
        surround.append(pixels[y * width + x])
      }
    }
    let wb = whiteBalance(surround)

    var patch: [UInt32] = []
    patch.reserveCapacity(side * side)
    for y in y0..<(y0 + side) {
      for x in x0..<(x0 + side) { patch.append(pixels[y * width + x]) }
    }
    let patchMean = Double(patch.map(ColourSpace.luma).reduce(0, +)) / Double(patch.count)
    // Blown out to white (every channel), not just one saturated channel (a vivid red has R = 255).
    let clipped = Double(patch.filter { minChannel($0) >= clip }.count) / Double(patch.count)

    if frameP95 < 45 || frameMean < 15 { return abstain(.tooDark, wb, frameMean) }
    if clipped > 0.5 { return abstain(.glare, wb, frameMean) }

    // Balanced patch, in linear RGB and OKLab.
    let lin = patch.map { pixel -> LinearRGB in
      let c = ColourSpace.linear(pixel)
      return LinearRGB(r: c.r * wb.gainR, g: c.g * wb.gainG, b: c.b * wb.gainB)
    }
    let labs = lin.map(ColourSpace.oklab)
    var clusters = twoMeans(labs)
    if clusters.count == 2, clusters[1].count > clusters[0].count { clusters.swapAt(0, 1) }
    func part(_ cluster: [Int]) -> ColourPart {
      let mean = meanLab(cluster.map { labs[$0] })
      let swatch = ColourSpace.argb(meanLinear(cluster.map { lin[$0] }))
      return ColourPart(match: ColourPalette.nearest(mean), share: Double(cluster.count) / Double(labs.count), swatch: swatch)
    }
    var parts = clusters.map(part)
    // Two groups that are really one colour (noise, shading): merge them back.
    if parts.count == 2,
      parts[0].match.colour.name == parts[1].match.colour.name
        || parts[0].match.measured.distance(to: parts[1].match.measured) <= minSecondDistance
    {
      clusters = [Array(labs.indices)]
      parts = [part(clusters[0])]
    }
    let main = parts[0]
    // A small group (a speck, an edge, a logo) is left out of the main colour but not named.
    let second = parts.count > 1 && parts[1].share >= minSecondShare ? parts[1] : nil

    // Spread inside the main group: a busy pattern or a noisy, badly lit patch.
    let mainIndices = clusters[0]
    let centre = main.match.measured
    let spread = (mainIndices.map { pow(labs[$0].distance(to: centre), 2) }.reduce(0, +) / Double(mainIndices.count)).squareRoot()

    var confidence = ColourConfidence.confident
    var reasons: [ColourHedgeReason] = []
    func atMost(_ c: ColourConfidence, _ r: ColourHedgeReason) {
      if c > confidence { confidence = c }
      if !reasons.contains(r) { reasons.append(r) }
    }
    let castReason: ColourHedgeReason =
      wb.warmth > 1.15 ? .warmLight : (wb.warmth < 1 / 1.15 ? .coolLight : .tintedLight)
    let chroma = centre.chroma
    let chromatic = main.match.colour.family != .neutral

    if frameMean < 35 {
      atMost(.unsure, .veryDim)
    } else if frameMean < 60 {
      atMost(.probable, .dim)
    }
    if wb.cast > 3.0 {
      atMost(.unsure, castReason)
    } else if wb.cast > 1.5 && chroma < 0.10 {
      atMost(.unsure, castReason)
    } else if wb.cast > 1.3 {
      atMost(.probable, castReason)
    }
    if chromatic && chroma < 0.05 { atMost(.probable, .muted) }
    if main.match.ambiguous { atMost(.probable, .between) }
    if chromatic && patchMean < 30 && chroma < 0.1 { atMost(.probable, .darkObject) }
    if spread > 0.12 { atMost(.probable, .busyPattern) }

    return ColourResult(
      confidence: confidence, main: main, second: second, reasons: reasons, whiteBalance: wb, frameLuma: frameMean, swatch: main.swatch)
  }

  private static func abstain(_ reason: ColourHedgeReason, _ wb: WhiteBalance, _ frameMean: Double) -> ColourResult {
    ColourResult(
      confidence: .abstain, main: nil, second: nil, reasons: [reason], whiteBalance: wb, frameLuma: frameMean,
      swatch: ColourSpace.argb(60, 60, 60))
  }

  /// Grey-world and white-patch estimates from `pixels`, combined; see the header.
  static func whiteBalance(_ pixels: [UInt32]) -> WhiteBalance {
    let usable = pixels.filter { maxChannel($0) < clip && ColourSpace.luma($0) >= 12 }
    guard usable.count >= 50 else { return .none }
    let lin = usable.map(ColourSpace.linear)
    let grey = meanLinear(lin)
    let lumas = usable.map(ColourSpace.luma)
    // Stable, as Kotlin's sortedByDescending: ties keep their order.
    let byLuma = usable.indices.sorted { lumas[$0] != lumas[$1] ? lumas[$0] > lumas[$1] : $0 < $1 }
    let top = byLuma.prefix(max(10, usable.count * 3 / 100)).map { lin[$0] }
    let white = meanLinear(Array(top))
    // Gains that make each estimate neutral, in log space so they combine and normalise cleanly.
    func logGains(_ c: LinearRGB) -> [Double] {
      let e = 1e-4
      let m = (log(c.r + e) + log(c.g + e) + log(c.b + e)) / 3
      return [m - log(c.r + e), m - log(c.g + e), m - log(c.b + e)]
    }
    let gw = logGains(grey)
    let wp = logGains(white)
    let limit = log(maxGain)
    let raw = (0..<3).map { min(max((gw[$0] + wp[$0]) / 2, -limit), limit) }
    let cast = exp(raw.max()! - raw.min()!)
    let warmth = exp(raw[2] - raw[0])
    return WhiteBalance(
      gainR: exp(raw[0] * wbStrength), gainG: exp(raw[1] * wbStrength), gainB: exp(raw[2] * wbStrength), cast: cast, warmth: warmth)
  }

  /// Splits `labs` into at most two groups (indices). One group if they're all much the same.
  static func twoMeans(_ labs: [Oklab]) -> [[Int]] {
    let all = Array(labs.indices)
    guard labs.count >= 4 else { return [all] }
    let mean = meanLab(labs)
    let i1 = all.max { labs[$0].distance(to: mean) < labs[$1].distance(to: mean) }!
    let i2 = all.max { labs[$0].distance(to: labs[i1]) < labs[$1].distance(to: labs[i1]) }!
    if labs[i1].distance(to: labs[i2]) < 0.06 { return [all] }
    var c1 = labs[i1]
    var c2 = labs[i2]
    var assign = [Bool](repeating: false, count: labs.count)
    for _ in 0..<10 {
      let next = labs.map { $0.distance(to: c2) < $0.distance(to: c1) }
      let g1 = all.filter { !next[$0] }
      let g2 = all.filter { next[$0] }
      if g1.isEmpty || g2.isEmpty { return [all] }
      c1 = meanLab(g1.map { labs[$0] })
      c2 = meanLab(g2.map { labs[$0] })
      if next == assign { return [g1, g2] }
      assign = next
    }
    return [all.filter { !assign[$0] }, all.filter { assign[$0] }]
  }

  private static func meanLab(_ c: [Oklab]) -> Oklab {
    let n = Double(c.count)
    return Oklab(l: c.map(\.l).reduce(0, +) / n, a: c.map(\.a).reduce(0, +) / n, b: c.map(\.b).reduce(0, +) / n)
  }

  private static func meanLinear(_ c: [LinearRGB]) -> LinearRGB {
    let n = Double(c.count)
    return LinearRGB(r: c.map(\.r).reduce(0, +) / n, g: c.map(\.g).reduce(0, +) / n, b: c.map(\.b).reduce(0, +) / n)
  }

  private static func maxChannel(_ argb: UInt32) -> Int {
    max(ColourSpace.red(argb), ColourSpace.green(argb), ColourSpace.blue(argb))
  }

  private static func minChannel(_ argb: UInt32) -> Int {
    min(ColourSpace.red(argb), ColourSpace.green(argb), ColourSpace.blue(argb))
  }

  private static func percentile(_ values: [Int], _ p: Double) -> Int {
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
  }
}

/// The spoken answer for a ColourResult. English; the screen shows the same text.
enum ColourSpeech {
  static func describe(_ r: ColourResult) -> String {
    guard r.confidence != .abstain, let main = r.main else {
      if r.reasons.first == .glare { return "Too much glare to tell. Tilt it away from the light and say again." }
      return "Too dark to tell. Turn a light on, or hold it nearer a window, and say again."
    }
    let names = colours(main, r.second)
    let sentence: String
    switch r.confidence {
    case .confident:
      sentence = capitalized(names) + "."
    case .probable:
      if let alt = main.match.runnerUp, r.reasons.contains(.between), r.second == nil {
        sentence = "Probably \(names), or maybe \(alt.name)."
      } else {
        sentence = "Probably \(names)."
      }
    default:
      sentence = "Hard to tell in this light. It might be \(names)."
    }
    if r.confidence != .confident, let why = r.reasons.lazy.compactMap(reasonText).first {
      return "\(sentence) \(why)"
    }
    return sentence
  }

  /// "navy blue", "mostly white, with blue", "white and blue".
  static func colours(_ main: ColourPart, _ second: ColourPart?) -> String {
    guard let second else { return main.match.name }
    if main.share >= 0.6 { return "mostly \(main.match.name), with \(second.match.name)" }
    return "\(main.match.name) and \(second.match.name)"
  }

  private static func reasonText(_ r: ColourHedgeReason) -> String? {
    switch r {
    case .veryDim, .dim: "The light is dim."
    case .warmLight: "The light looks yellowish, which shifts colours."
    case .coolLight: "The light looks bluish, which shifts colours."
    case .tintedLight: "The light looks tinted."
    case .muted: "It's a muted colour."
    case .darkObject: "It's very dark."
    case .busyPattern: "It looks patterned."
    default: nil
    }
  }

  private static func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
}
