/*
 * ColourPalette - the everyday colour names the tool can say, and picking the nearest one
 *
 * Port of Android's tools/light/ColourPalette.kt. Names are the ones a person would use about
 * clothes, towels or a mug ("navy blue", "beige", "burgundy", "dark green"), not paint-chart names.
 * Each has a typical sRGB value, converted to OKLab once, and a family (red, blue, neutral...) so
 * the tool can tell "between navy and black" (different families: worth hedging) from "between navy
 * and dark blue" (same answer, really). Naming is nearest neighbour in OKLab, with lightness weighted
 * a little less than hue and chroma, because lighting changes lightness most. A plain hue name
 * ("blue", "green") gets a "light" or "dark" modifier when the measured colour is clearly lighter or
 * darker than the palette's one.
 */

import Foundation

enum ColourFamily: Sendable {
  case neutral, red, pink, purple, blue, teal, green, yellow, orange, brown
}

struct PaletteColour: Equatable, Sendable {
  var name: String
  var r: Int
  var g: Int
  var b: Int
  var family: ColourFamily
  /// True for plain names that can take "light"/"dark" ("blue" -> "dark blue").
  var modifiable = false
  let lab: Oklab

  init(_ name: String, _ r: Int, _ g: Int, _ b: Int, _ family: ColourFamily, modifiable: Bool = false) {
    self.name = name
    self.r = r
    self.g = g
    self.b = b
    self.family = family
    self.modifiable = modifiable
    lab = ColourSpace.oklab(r, g, b)
  }
}

/// The palette's nearest entry to a measured colour, its spoken name, and the runner-up.
struct ColourMatch: Equatable, Sendable {
  var colour: PaletteColour
  /// Spoken name, with any light/dark modifier ("dark blue").
  var name: String
  var distance: Double
  /// The nearest entry from a *different* family, and its distance.
  var runnerUp: PaletteColour?
  var runnerUpDistance: Double
  var measured: Oklab

  static let ambiguousRatio = 1.2
  static let ambiguousSlack = 0.006

  /// Measured colour sits between two families: hedge ("probably teal, or maybe green").
  var ambiguous: Bool { runnerUp != nil && runnerUpDistance < distance * Self.ambiguousRatio + Self.ambiguousSlack }
}

enum ColourPalette {
  static let colours: [PaletteColour] = [
    // Neutrals. Black to white by lightness.
    PaletteColour("black", 18, 18, 18, .neutral),
    PaletteColour("dark grey", 70, 70, 70, .neutral),
    PaletteColour("grey", 128, 128, 128, .neutral),
    PaletteColour("light grey", 190, 190, 190, .neutral),
    PaletteColour("white", 245, 245, 245, .neutral),
    PaletteColour("cream", 245, 235, 205, .yellow),
    PaletteColour("beige", 215, 195, 160, .brown),
    // Reds and pinks.
    PaletteColour("red", 205, 30, 35, .red, modifiable: true),
    PaletteColour("dark red", 135, 20, 25, .red),
    PaletteColour("burgundy", 100, 20, 45, .red),
    PaletteColour("coral", 245, 115, 95, .orange),
    PaletteColour("pink", 240, 140, 175, .pink, modifiable: true),
    PaletteColour("light pink", 250, 205, 215, .pink),
    PaletteColour("hot pink", 230, 50, 140, .pink),
    // Purples.
    PaletteColour("purple", 120, 45, 160, .purple, modifiable: true),
    PaletteColour("dark purple", 65, 25, 85, .purple),
    PaletteColour("lilac", 190, 160, 220, .purple),
    // Oranges, yellows, browns.
    PaletteColour("orange", 245, 130, 25, .orange, modifiable: true),
    PaletteColour("peach", 250, 195, 155, .orange),
    PaletteColour("rust", 165, 70, 30, .orange),
    PaletteColour("yellow", 245, 220, 40, .yellow, modifiable: true),
    PaletteColour("pale yellow", 250, 240, 150, .yellow),
    PaletteColour("mustard", 200, 160, 30, .yellow),
    PaletteColour("brown", 120, 70, 35, .brown, modifiable: true),
    PaletteColour("dark brown", 65, 40, 22, .brown),
    PaletteColour("tan", 190, 145, 95, .brown),
    PaletteColour("khaki", 175, 165, 110, .brown),
    // Greens.
    PaletteColour("olive green", 105, 105, 35, .green),
    PaletteColour("lime green", 150, 210, 50, .green),
    PaletteColour("green", 40, 150, 60, .green, modifiable: true),
    PaletteColour("dark green", 20, 80, 35, .green),
    PaletteColour("light green", 150, 215, 140, .green),
    PaletteColour("mint green", 175, 230, 205, .green),
    // Teals and blues.
    PaletteColour("teal", 0, 125, 125, .teal),
    PaletteColour("turquoise", 50, 200, 200, .teal),
    PaletteColour("light blue", 150, 200, 240, .blue),
    PaletteColour("blue", 40, 90, 205, .blue, modifiable: true),
    PaletteColour("navy blue", 20, 30, 95, .blue),
    PaletteColour("grey-blue", 105, 125, 155, .blue),
  ]

  /// Lightness counts for this much of a difference as hue and chroma do.
  static let lightnessWeight = 0.75

  /// How much lighter or darker than a plain name before it gets "light"/"dark".
  static let modifierDeltaL = 0.12

  static func nearest(_ c: Oklab) -> ColourMatch {
    // Stable, as Kotlin's sortedBy: equal distances keep the palette's order.
    let ranked = colours.enumerated().map { ($0.element, c.distance(to: $0.element.lab, lightnessWeight: lightnessWeight), $0.offset) }
      .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.2 < $1.2 }
      .map { ($0.0, $0.1) }
    let (best, d) = ranked[0]
    let runner = ranked.first { $0.0.family != best.family }
    var name = best.name
    if best.modifiable {
      if c.l - best.lab.l > modifierDeltaL {
        name = "light \(best.name)"
      } else if best.lab.l - c.l > modifierDeltaL {
        name = "dark \(best.name)"
      }
    }
    return ColourMatch(
      colour: best, name: name, distance: d, runnerUp: runner?.0, runnerUpDistance: runner?.1 ?? .greatestFiniteMagnitude, measured: c)
  }
}
