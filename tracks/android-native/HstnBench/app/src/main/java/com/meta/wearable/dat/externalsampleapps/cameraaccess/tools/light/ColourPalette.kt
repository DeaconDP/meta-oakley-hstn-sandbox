// ColourPalette - the everyday colour names the tool can say, and picking the nearest one
//
// Names are the ones a person would use about clothes, towels or a mug ("navy blue", "beige",
// "burgundy", "dark green"), not paint-chart names. Each has a typical sRGB value, converted to
// OKLab once, and a family (red, blue, neutral...) so the tool can tell "between navy and black"
// (different families: worth hedging) from "between navy and dark blue" (same answer, really).
// Naming is nearest neighbour in OKLab, with lightness weighted a little less than hue and chroma,
// because lighting changes lightness most. A plain hue name ("blue", "green") gets a "light" or
// "dark" modifier when the measured colour is clearly lighter or darker than the palette's one.
// Pure Kotlin (no Android imports), JVM-tested.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.light

enum class ColourFamily { NEUTRAL, RED, PINK, PURPLE, BLUE, TEAL, GREEN, YELLOW, ORANGE, BROWN }

data class PaletteColour(
    val name: String,
    val r: Int,
    val g: Int,
    val b: Int,
    val family: ColourFamily,
    /** True for plain names that can take "light"/"dark" ("blue" -> "dark blue"). */
    val modifiable: Boolean = false,
) {
  val lab: Oklab = ColourSpace.oklab(r, g, b)
}

/** The palette's nearest entry to a measured colour, its spoken name, and the runner-up. */
data class ColourMatch(
    val colour: PaletteColour,
    /** Spoken name, with any light/dark modifier ("dark blue"). */
    val name: String,
    val distance: Double,
    /** The nearest entry from a *different* family, and its distance. */
    val runnerUp: PaletteColour?,
    val runnerUpDistance: Double,
    val measured: Oklab,
) {
  /** Measured colour sits between two families: hedge ("probably teal, or maybe green"). */
  val ambiguous: Boolean
    get() = runnerUp != null && runnerUpDistance < distance * AMBIGUOUS_RATIO + AMBIGUOUS_SLACK

  companion object {
    const val AMBIGUOUS_RATIO = 1.2
    const val AMBIGUOUS_SLACK = 0.006
  }
}

object ColourPalette {

  private val N = ColourFamily.NEUTRAL

  val COLOURS: List<PaletteColour> =
      listOf(
          // Neutrals. Black to white by lightness.
          PaletteColour("black", 18, 18, 18, N),
          PaletteColour("dark grey", 70, 70, 70, N),
          PaletteColour("grey", 128, 128, 128, N),
          PaletteColour("light grey", 190, 190, 190, N),
          PaletteColour("white", 245, 245, 245, N),
          PaletteColour("cream", 245, 235, 205, ColourFamily.YELLOW),
          PaletteColour("beige", 215, 195, 160, ColourFamily.BROWN),
          // Reds and pinks.
          PaletteColour("red", 205, 30, 35, ColourFamily.RED, modifiable = true),
          PaletteColour("dark red", 135, 20, 25, ColourFamily.RED),
          PaletteColour("burgundy", 100, 20, 45, ColourFamily.RED),
          PaletteColour("coral", 245, 115, 95, ColourFamily.ORANGE),
          PaletteColour("pink", 240, 140, 175, ColourFamily.PINK, modifiable = true),
          PaletteColour("light pink", 250, 205, 215, ColourFamily.PINK),
          PaletteColour("hot pink", 230, 50, 140, ColourFamily.PINK),
          // Purples.
          PaletteColour("purple", 120, 45, 160, ColourFamily.PURPLE, modifiable = true),
          PaletteColour("dark purple", 65, 25, 85, ColourFamily.PURPLE),
          PaletteColour("lilac", 190, 160, 220, ColourFamily.PURPLE),
          // Oranges, yellows, browns.
          PaletteColour("orange", 245, 130, 25, ColourFamily.ORANGE, modifiable = true),
          PaletteColour("peach", 250, 195, 155, ColourFamily.ORANGE),
          PaletteColour("rust", 165, 70, 30, ColourFamily.ORANGE),
          PaletteColour("yellow", 245, 220, 40, ColourFamily.YELLOW, modifiable = true),
          PaletteColour("pale yellow", 250, 240, 150, ColourFamily.YELLOW),
          PaletteColour("mustard", 200, 160, 30, ColourFamily.YELLOW),
          PaletteColour("brown", 120, 70, 35, ColourFamily.BROWN, modifiable = true),
          PaletteColour("dark brown", 65, 40, 22, ColourFamily.BROWN),
          PaletteColour("tan", 190, 145, 95, ColourFamily.BROWN),
          PaletteColour("khaki", 175, 165, 110, ColourFamily.BROWN),
          // Greens.
          PaletteColour("olive green", 105, 105, 35, ColourFamily.GREEN),
          PaletteColour("lime green", 150, 210, 50, ColourFamily.GREEN),
          PaletteColour("green", 40, 150, 60, ColourFamily.GREEN, modifiable = true),
          PaletteColour("dark green", 20, 80, 35, ColourFamily.GREEN),
          PaletteColour("light green", 150, 215, 140, ColourFamily.GREEN),
          PaletteColour("mint green", 175, 230, 205, ColourFamily.GREEN),
          // Teals and blues.
          PaletteColour("teal", 0, 125, 125, ColourFamily.TEAL),
          PaletteColour("turquoise", 50, 200, 200, ColourFamily.TEAL),
          PaletteColour("light blue", 150, 200, 240, ColourFamily.BLUE),
          PaletteColour("blue", 40, 90, 205, ColourFamily.BLUE, modifiable = true),
          PaletteColour("navy blue", 20, 30, 95, ColourFamily.BLUE),
          PaletteColour("grey-blue", 105, 125, 155, ColourFamily.BLUE),
      )

  /** Lightness counts for this much of a difference as hue and chroma do. */
  const val LIGHTNESS_WEIGHT = 0.75

  /** How much lighter or darker than a plain name before it gets "light"/"dark". */
  const val MODIFIER_DELTA_L = 0.12

  fun nearest(c: Oklab): ColourMatch {
    val ranked = COLOURS.map { it to c.distanceTo(it.lab, LIGHTNESS_WEIGHT) }.sortedBy { it.second }
    val (best, d) = ranked.first()
    val runner = ranked.firstOrNull { it.first.family != best.family }
    val name =
        if (!best.modifiable) best.name
        else when {
          c.l - best.lab.l > MODIFIER_DELTA_L -> "light ${best.name}"
          best.lab.l - c.l > MODIFIER_DELTA_L -> "dark ${best.name}"
          else -> best.name
        }
    return ColourMatch(best, name, d, runner?.first, runner?.second ?: Double.MAX_VALUE, c)
  }
}
