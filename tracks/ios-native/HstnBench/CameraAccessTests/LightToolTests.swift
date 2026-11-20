/*
 * LightToolTests - the light and colour tool's pure logic, ported from Android's JVM tests
 * (tools/light: ColourReaderTest, LightProbeTest, LightFixtures)
 *
 * Synthetic frames: a surround (the room) with an object in the middle, optionally striped, then
 * optionally lit by a coloured light (each channel scaled in linear light, as a warm bulb would) and
 * given a little deterministic noise like a compressed camera stream. Known sRGB patches get their
 * everyday names; the same colours under warm light are hedged and never confidently called
 * something else; dark frames abstain; stripes give two colours; OKLab matches published values.
 * The probe: log pitch, smoothing, levels, the brightest side, and blinking.
 */

import XCTest

@testable import CameraAccess

/// A deterministic generator standing in for Kotlin's seeded Random.
private struct Lcg {
  var state: UInt64
  init(_ seed: Int) { state = UInt64(bitPattern: Int64(seed)) &* 2_862_933_555_777_941_757 &+ 3_037_000_493 }
  /// lower...upper inclusive.
  mutating func next(_ lower: Int, _ upper: Int) -> Int {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return lower + Int((state >> 33) % UInt64(upper - lower + 1))
  }
  mutating func unit() -> Double {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Double(state >> 11) / Double(1 << 53)
  }
}

private struct RGB: CustomStringConvertible {
  var r: Int
  var g: Int
  var b: Int
  init(_ r: Int, _ g: Int, _ b: Int) {
    self.r = r
    self.g = g
    self.b = b
  }
  var description: String { "(\(r), \(g), \(b))" }
}

private enum Fixtures {
  static let w = 160
  static let h = 288

  /// Warm tungsten-like light: less blue, a bit less green.
  static let warm = (1.0, 0.78, 0.48)
  static let veryWarm = (1.0, 0.62, 0.28)

  static func frame(
    _ colour: RGB, surround: RGB = RGB(128, 128, 128), objectFraction: Double = 0.4, stripe: RGB? = nil, stripeShare: Double = 0.3,
    light: (Double, Double, Double)? = nil, exposure: Double = 1, noise: Int = 3, w: Int = w, h: Int = h, seed: Int = 1
  ) -> [UInt32] {
    var rnd = Lcg(seed)
    let side = Int(Double(w) * objectFraction)
    let x0 = w / 2 - side / 2
    let y0 = h / 2 - side / 2
    let period = 10
    return (0..<(w * h)).map { i in
      let x = i % w
      let y = i / w
      let inside = x >= x0 && x < x0 + side && y >= y0 && y < y0 + side
      let c: RGB
      if !inside {
        c = surround
      } else if let stripe, Double((x - x0) % period) < Double(period) * stripeShare {
        c = stripe
      } else {
        c = colour
      }
      return lit(c, light, exposure, noise > 0 ? rnd.next(-noise, noise) : 0)
    }
  }

  static func uniform(_ c: RGB, w: Int = 96, h: Int = 172) -> [UInt32] {
    [UInt32](repeating: ColourSpace.argb(c.r, c.g, c.b), count: w * h)
  }

  private static func lit(_ c: RGB, _ light: (Double, Double, Double)?, _ exposure: Double, _ n: Int) -> UInt32 {
    func ch(_ v: Int, _ k: Double) -> Int { ColourSpace.toSrgb(ColourSpace.toLinear(v) * k * exposure) + n }
    let l = light ?? (1, 1, 1)
    return ColourSpace.argb(ch(c.r, l.0), ch(c.g, l.1), ch(c.b, l.2))
  }

  static func read(_ frame: [UInt32]) -> ColourResult { ColourReader.read(frame, width: w, height: h)! }
}

// MARK: - Colour

final class ColourReaderTests: XCTestCase {
  private func say(_ r: ColourResult) -> String { ColourSpeech.describe(r) }

  func testOklabMatchesReferenceValues() {
    let white = ColourSpace.oklab(255, 255, 255)
    XCTAssertEqual(white.l, 1.0, accuracy: 0.001)
    XCTAssertEqual(white.chroma, 0.0, accuracy: 0.001)
    // Ottosson's reference: sRGB red = (0.628, 0.225, 0.126).
    let red = ColourSpace.oklab(255, 0, 0)
    XCTAssertEqual(red.l, 0.628, accuracy: 0.002)
    XCTAssertEqual(red.a, 0.225, accuracy: 0.002)
    XCTAssertEqual(red.b, 0.126, accuracy: 0.002)
    let blue = ColourSpace.oklab(0, 0, 255)
    XCTAssertEqual(blue.l, 0.452, accuracy: 0.002)
    XCTAssertEqual(blue.a, -0.032, accuracy: 0.002)
    XCTAssertEqual(blue.b, -0.312, accuracy: 0.002)
    for v in [0, 1, 10, 50, 128, 200, 254, 255] { XCTAssertEqual(ColourSpace.toSrgb(ColourSpace.toLinear(v)), v) }
  }

  func testKnownPatchesInNeutralLightGetTheirNamesConfidently() {
    let expected: [(RGB, String)] = [
      (RGB(0, 0, 128), "Navy blue."), (RGB(20, 30, 95), "Navy blue."), (RGB(255, 0, 0), "Red."), (RGB(205, 30, 35), "Red."),
      (RGB(100, 20, 45), "Burgundy."), (RGB(20, 80, 35), "Dark green."), (RGB(0, 128, 0), "Green."), (RGB(215, 195, 160), "Beige."),
      (RGB(128, 128, 128), "Grey."), (RGB(15, 15, 15), "Black."), (RGB(245, 245, 245), "White."), (RGB(255, 192, 203), "Light pink."),
      (RGB(240, 140, 175), "Pink."), (RGB(245, 130, 25), "Orange."), (RGB(120, 70, 35), "Brown."), (RGB(128, 0, 128), "Purple."),
      (RGB(65, 105, 225), "Blue."), (RGB(135, 206, 235), "Light blue."), (RGB(0, 128, 128), "Teal."), (RGB(255, 255, 0), "Yellow."),
      (RGB(128, 128, 0), "Olive green."), (RGB(255, 127, 80), "Coral."), (RGB(64, 224, 208), "Turquoise."),
    ]
    for (c, name) in expected {
      let r = Fixtures.read(Fixtures.frame(c))
      XCTAssertEqual(say(r), name, "\(c)")
      XCTAssertEqual(r.confidence, .confident, "\(c)")
    }
  }

  func testLightAndDarkModifiers() {
    let blue = ColourPalette.colours.first { $0.name == "blue" }!.lab
    var darkerLab = blue
    darkerLab.l -= 0.13
    let darker = ColourPalette.nearest(darkerLab).name
    XCTAssertTrue(darker == "dark blue" || darker == "navy blue", darker)
    XCTAssertEqual(ColourPalette.nearest(ColourSpace.oklab(150, 200, 240)).name, "light blue")
    // Just past the threshold, plain names get the modifier (unless a named shade is nearer).
    let modified = ColourPalette.colours.filter(\.modifiable).flatMap { c in
      [0.125, -0.125].map { dl -> (String, String) in
        var lab = c.lab
        lab.l += dl
        return (c.name, ColourPalette.nearest(lab).name)
      }
    }
    XCTAssertGreaterThanOrEqual(modified.filter { $0.1 == "light \($0.0)" || $0.1 == "dark \($0.0)" }.count, 3, "\(modified)")
    XCTAssertFalse(modified.contains { $0.1.hasPrefix("light light") || $0.1.hasPrefix("dark dark") }, "\(modified)")
    // Names that already carry their shade don't get another.
    XCTAssertEqual(ColourPalette.nearest(ColourSpace.oklab(20, 30, 95)).name, "navy blue")
  }

  func testBetweenTwoFamiliesIsHedgedWithBothNames() {
    let r = Fixtures.read(Fixtures.frame(RGB(255, 165, 0)))
    XCTAssertEqual(r.confidence, .probable)
    XCTAssertTrue(say(r).hasPrefix("Probably orange, or maybe"), say(r))
  }

  func testRedUnderWarmLightIsStillRedOrHedgedNeverConfidentlyOrange() {
    for red in [RGB(205, 30, 35), RGB(255, 0, 0), RGB(180, 20, 30), RGB(150, 25, 30)] {
      for light in [Fixtures.warm, Fixtures.veryWarm] {
        let r = Fixtures.read(Fixtures.frame(red, light: light))
        let text = say(r)
        XCTAssertNotEqual(r.confidence, .confident, "\(red) \(light): \(text)")
        XCTAssertEqual(r.main?.match.colour.family, .red, "\(red) \(light): \(text)")
        XCTAssertFalse(text.contains("orange") || text.contains("coral"), "\(red) \(light): \(text)")
        XCTAssertTrue(text.contains("yellowish"), text)
      }
    }
  }

  func testNoColourIsConfidentUnderAStrongCast() {
    for c in ColourPalette.colours {
      for light in [Fixtures.warm, Fixtures.veryWarm] {
        let r = Fixtures.read(Fixtures.frame(RGB(c.r, c.g, c.b), light: light))
        XCTAssertNotEqual(r.confidence, .confident, "\(c.name) \(light): \(say(r))")
      }
    }
    // A very strong cast on white gives "hard to tell", not a confident "cream".
    let white = Fixtures.read(Fixtures.frame(RGB(245, 245, 245), light: Fixtures.veryWarm))
    XCTAssertEqual(white.confidence, .unsure)
    XCTAssertTrue(say(white).hasPrefix("Hard to tell in this light."), say(white))
  }

  func testWhiteBalanceMeasuresTheCastAndCorrectsIt() {
    let neutral = ColourReader.whiteBalance(Fixtures.frame(RGB(128, 128, 128)))
    XCTAssertEqual(neutral.cast, 1.0, accuracy: 0.05)
    let warm = ColourReader.whiteBalance(Fixtures.frame(RGB(128, 128, 128), light: Fixtures.warm))
    XCTAssertGreaterThan(warm.cast, 1.8)
    XCTAssertGreaterThan(warm.warmth, 1.8)
    XCTAssertGreaterThan(warm.gainB, warm.gainR, "blue boosted")
    // Moderately warm light: the correction brings red back to red (hedged for the cast).
    let r = Fixtures.read(Fixtures.frame(RGB(205, 30, 35), light: Fixtures.warm))
    XCTAssertEqual(r.main?.match.name, "red")
    XCTAssertEqual(r.confidence, .probable)
    XCTAssertEqual(say(r), "Probably red. The light looks yellowish, which shifts colours.")
  }

  func testDarkFrameIsTooDarkToTell() {
    let r = Fixtures.read(Fixtures.frame(RGB(30, 10, 10), surround: RGB(10, 10, 10), noise: 2))
    XCTAssertEqual(r.confidence, .abstain)
    XCTAssertNil(r.main)
    XCTAssertTrue(say(r).hasPrefix("Too dark to tell."), say(r))
    // Same scene underexposed from a normal one.
    XCTAssertEqual(Fixtures.read(Fixtures.frame(RGB(205, 30, 35), exposure: 0.01)).confidence, .abstain)
  }

  func testDimLightIsHedged() {
    let r = Fixtures.read(Fixtures.frame(RGB(205, 30, 35), exposure: 0.12))
    XCTAssertTrue(r.confidence == .probable || r.confidence == .unsure, "\(r.confidence) \(say(r))")
    XCTAssertTrue(say(r).contains("dim"), say(r))
    let veryDim = Fixtures.read(Fixtures.frame(RGB(205, 30, 35), exposure: 0.05))
    XCTAssertGreaterThanOrEqual(veryDim.confidence, .unsure, say(veryDim))
  }

  func testBlackInGoodLightIsBlackNotTooDark() {
    XCTAssertEqual(say(Fixtures.read(Fixtures.frame(RGB(15, 15, 15), surround: RGB(170, 170, 170)))), "Black.")
  }

  func testGlareAbstains() {
    let r = Fixtures.read(Fixtures.frame(RGB(255, 255, 255), surround: RGB(150, 150, 150), noise: 0))
    XCTAssertEqual(r.confidence, .abstain)
    XCTAssertTrue(say(r).hasPrefix("Too much glare"), say(r))
  }

  func testMutedColourIsHedged() {
    let r = Fixtures.read(Fixtures.frame(RGB(245, 245, 220)))
    XCTAssertEqual(r.confidence, .probable)
    XCTAssertTrue(say(r).hasPrefix("Probably cream"), say(r))
  }

  func testStripesGiveTwoColours() {
    // 70% white, 30% blue.
    XCTAssertEqual(say(Fixtures.read(Fixtures.frame(RGB(245, 245, 245), stripe: RGB(40, 90, 205), stripeShare: 0.3))), "Mostly white, with blue.")
    // Even stripes.
    let even = say(Fixtures.read(Fixtures.frame(RGB(245, 245, 245), stripe: RGB(20, 30, 95), stripeShare: 0.5)))
    XCTAssertTrue(even == "White and navy blue." || even == "Navy blue and white.", even)
    // A thin pinstripe (10%) doesn't count as a second colour.
    XCTAssertEqual(say(Fixtures.read(Fixtures.frame(RGB(20, 30, 95), stripe: RGB(245, 245, 245), stripeShare: 0.1))), "Navy blue.")
  }

  func testBackgroundAroundASmallPatchDoesNotChangeTheAnswer() {
    let r = Fixtures.read(Fixtures.frame(RGB(205, 30, 35), surround: RGB(60, 160, 60), objectFraction: 0.25))
    XCTAssertEqual(r.main?.match.name, "red")
    XCTAssertNil(r.second)
  }

  func testSwatchIsTheBalancedColour() {
    let s = Fixtures.read(Fixtures.frame(RGB(20, 30, 95), noise: 0)).swatch
    XCTAssertEqual(Double(ColourSpace.red(s)), 20, accuracy: 3)
    XCTAssertEqual(Double(ColourSpace.green(s)), 30, accuracy: 3)
    XCTAssertEqual(Double(ColourSpace.blue(s)), 95, accuracy: 3)
  }
}

// MARK: - Light probe

final class LightProbeTests: XCTestCase {
  private let w = 96
  private let h = 172

  private func grey(_ v: Int) -> [UInt32] { Fixtures.uniform(RGB(v, v, v), w: w, h: h) }
  private func reading(_ v: Int) -> LightReading { LightMeter.measure(grey(v), width: w, height: h)! }

  func testPitchRisesMonotonicallyWithBrightness() {
    var last = 0.0
    for v in 0...255 {
      let hz = PitchMap.frequency(forLuminance: reading(v).luminance)
      XCTAssertGreaterThanOrEqual(hz, last, "\(v)")
      last = hz
    }
    XCTAssertEqual(PitchMap.frequency(forLuminance: 0), PitchMap.minHz, accuracy: 0.01)
    XCTAssertEqual(PitchMap.frequency(forLuminance: 1), PitchMap.maxHz, accuracy: 0.01)
    XCTAssertLessThan(PitchMap.frequency(forLuminance: 0.01), PitchMap.frequency(forLuminance: 0.02))
  }

  func testPitchIsLogarithmicEachDoublingOfLightIsTheSameInterval() {
    // 9 stops over 3 octaves: a stop is a third of an octave, 2^(1/3).
    for l in [0.004, 0.01, 0.05, 0.2] {
      XCTAssertEqual(PitchMap.frequency(forLuminance: l * 2) / PitchMap.frequency(forLuminance: l), cbrt(2.0), accuracy: 0.001)
    }
    XCTAssertEqual(PitchMap.position(0.02) - PitchMap.position(0.01), log(2.0) / -log(PitchMap.floor), accuracy: 1e-9)
  }

  func testSmoothingSettlesWithoutOvershootAndIgnoresNoise() {
    var s = PitchSmoother()
    _ = s.update(0.2)
    var seen: [Double] = []
    for _ in 0..<12 { seen.append(s.update(0.8)) }
    XCTAssertTrue(zip(seen, seen.dropFirst()).allSatisfy { $0 <= $1 }, "rising: \(seen)")
    XCTAssertTrue(seen.allSatisfy { $0 <= 0.8 }, "no overshoot: \(seen)")
    XCTAssertLessThan(abs(seen.last! - 0.8), 0.01)
    // Noise of +-0.03 around 0.5 (compression flicker) moves the tone far less.
    var s2 = PitchSmoother()
    var rnd = Lcg(7)
    _ = s2.update(0.5)
    let input = (0..<60).map { _ in 0.5 + (rnd.unit() * 0.06 - 0.03) }
    let out = input.map { s2.update($0) }
    XCTAssertLessThan(out.max()! - out.min()!, 0.6 * (input.max()! - input.min()!))
    // A tiny change inside the dead band doesn't move it at all.
    var s3 = PitchSmoother()
    _ = s3.update(0.5)
    XCTAssertEqual(s3.update(0.505), 0.5, accuracy: 1e-9)
  }

  func testLevelsFromDarkToVeryBright() {
    XCTAssertEqual(LightMeter.level(reading(10)), .dark)
    XCTAssertEqual(LightMeter.level(reading(40)), .dim)
    XCTAssertEqual(LightMeter.level(reading(120)), .normal)
    XCTAssertEqual(LightMeter.level(reading(170)), .bright)
    XCTAssertEqual(LightMeter.level(reading(230)), .veryBright)
    // A blown-out window filling a third of the view is very bright even if the rest is normal.
    var px = grey(100)
    for i in 0..<(px.count * 2 / 5) { px[i] = ColourSpace.argb(255, 255, 255) }
    XCTAssertEqual(LightMeter.level(LightMeter.measure(px, width: w, height: h)!), .veryBright)
  }

  func testCentreCountsMoreThanTheEdges() {
    let bright = ColourSpace.argb(200, 200, 200)
    let dark = ColourSpace.argb(30, 30, 30)
    let centre = (0..<(w * h)).map { i -> UInt32 in
      let x = i % w
      let y = i / w
      return x >= w / 4 && x < w * 3 / 4 && y >= h / 4 && y < h * 3 / 4 ? bright : dark
    }
    let edges = centre.map { $0 == bright ? dark : bright }
    XCTAssertGreaterThan(LightMeter.measure(centre, width: w, height: h)!.luminance, LightMeter.measure(edges, width: w, height: h)!.luminance)
  }

  func testBrightestSide() {
    func scene(_ third: Int) -> [UInt32] {
      (0..<(w * h)).map { i in (i % w) * 3 / w == third ? ColourSpace.argb(230, 230, 230) : ColourSpace.argb(40, 40, 40) }
    }
    XCTAssertEqual(LightMeter.measure(scene(0), width: w, height: h)?.brightestSide, .left)
    XCTAssertEqual(LightMeter.measure(scene(1), width: w, height: h)?.brightestSide, .middle)
    XCTAssertEqual(LightMeter.measure(scene(2), width: w, height: h)?.brightestSide, .right)
    XCTAssertNil(reading(120).brightestSide)
  }

  // MARK: Blinking

  /// A dim room with a small LED at (60, 40) that's on in frames where `on` is true.
  private func led(on: Bool, seed: Int, size: Int = 3) -> [UInt32] {
    var rnd = Lcg(seed)
    return (0..<(w * h)).map { i in
      let x = i % w
      let y = i / w
      let base = 50 + (x / 12) * 3 + rnd.next(-4, 4)
      let v = on && x >= 60 && x < 60 + size && y >= 40 && y < 40 + size ? 240 : base
      return ColourSpace.argb(v, v, v)
    }
  }

  func testBlinkingLedIsDetected() {
    var f = FlickerDetector()
    var detectedAt = -1
    // On for 2 frames, off for 2 (1 Hz at 4 fps).
    for n in 0..<20 where f.update(led(on: (n / 2) % 2 == 0, seed: n), width: w, height: h) && detectedAt < 0 {
      detectedAt = n
    }
    XCTAssertTrue((5...10).contains(detectedAt), "detected at \(detectedAt)")
    XCTAssertTrue(f.blinking)
  }

  func testFastBlinkEveryFrameIsDetected() {
    var f = FlickerDetector()
    for n in 0..<12 { f.update(led(on: n % 2 == 0, seed: n), width: w, height: h) }
    XCTAssertTrue(f.blinking)
  }

  func testSteadyOrSwitchedOnceIsNotBlinking() {
    var steady = FlickerDetector()
    for n in 0..<20 { steady.update(led(on: true, seed: n), width: w, height: h) }
    XCTAssertFalse(steady.blinking)
    var once = FlickerDetector()
    for n in 0..<20 { once.update(led(on: n >= 8, seed: n), width: w, height: h) }
    XCTAssertFalse(once.blinking)
  }

  func testMovingTheCameraIsNotBlinking() {
    // A textured scene sliding sideways a few pixels per frame, back and forth.
    var f = FlickerDetector()
    for n in 0..<24 {
      let shift = [0, 8, 16, 8][n % 4]
      let px = (0..<(w * h)).map { i -> UInt32 in
        let x = (i % w) + shift
        let y = i / w
        let v = (x / 10 + y / 14) % 2 == 0 ? 220 : 40
        return ColourSpace.argb(v, v, v)
      }
      f.update(px, width: w, height: h)
    }
    XCTAssertFalse(f.blinking)
  }

  func testAFlashingRoomLightIsBlinking() {
    var f = FlickerDetector()
    for n in 0..<16 { f.update(grey((n / 2) % 2 == 0 ? 200 : 40), width: w, height: h) }
    XCTAssertTrue(f.blinking)
  }

  func testASlowFadeIsNotBlinking() {
    var f = FlickerDetector()
    for n in 0..<20 { f.update(grey(Int(40 + 100 * (0.5 + 0.5 * sin(Double(n) * 0.4)))), width: w, height: h) }
    XCTAssertFalse(f.blinking)
  }

  // MARK: Grammar

  func testCommandsInsideTheTool() {
    func check(_ command: LightCommand, _ phrases: [String]) {
      for p in phrases { XCTAssertEqual(LightGrammar.parse(p), command, p) }
    }
    check(
      .howBright,
      ["how bright is it", "How bright is it in here?", "is the light on", "are the lights on", "is it dark in here", "brightness", "are the curtains open"])
    check(.whereBright, ["where's the light", "where is the window", "which way is the window"])
    check(.isBlinking, ["is it blinking", "is that flashing", "is the light flickering"])
    check(.again, ["again", "check again", "what about this one", "try again"])
    check(.colour, ["what colour is this", "What color is it?", "colour mode", "switch to colour mode", "colours"])
    check(.light, ["light mode", "back to the light", "light detector", "tone mode"])
    check(.toneOff, ["tone off", "turn the tone off", "mute", "quiet", "pause"])
    check(.toneOn, ["tone on", "turn the tone back on", "unmute", "carry on"])
  }

  func testEverydayWordsAreLeftAlone() {
    for p in ["stop", "close", "help", "read my mail", "scan this", "watch for 42", "say that again"] {
      XCTAssertNil(LightGrammar.parse(p), p)
    }
    // Room chatter.
    for p in ["turn right at the lights", "it's a lovely colour", "the light was red"] { XCTAssertNil(LightGrammar.parse(p), p) }
  }

  @MainActor
  func testOpeningPhraseChoosesTheMode() {
    XCTAssertEqual(LightTool.mode(forOpeningPhrase: "what colour is this"), .colour)
    XCTAssertEqual(LightTool.mode(forOpeningPhrase: "What color is it?"), .colour)
    XCTAssertEqual(LightTool.mode(forOpeningPhrase: "is the light on"), .probe)
    XCTAssertEqual(LightTool.mode(forOpeningPhrase: "open light and colour"), .probe)
  }
}
