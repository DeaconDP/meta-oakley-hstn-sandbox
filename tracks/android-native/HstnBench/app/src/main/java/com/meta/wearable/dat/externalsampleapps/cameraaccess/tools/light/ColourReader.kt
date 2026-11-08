// ColourReader - "what colour is this?": names the thing in the middle of the view, honestly
//
// Input is a downscaled camera frame as packed ARGB pixels. Steps:
//  1. Centre patch: a square PATCH_FRACTION of the frame's width, in the middle. On the glasses'
//     wide camera that's about the size of a mug or a folded shirt held 30-40 cm in front of the
//     face, so it covers the object and not the room behind it.
//  2. White balance from the surround (the outer frame, outside the middle SURROUND_X of the width
//     and SURROUND_Y of the height, so an object bigger than the patch doesn't leak in): the average
//     of a grey-world estimate (the room averages to grey) and a white-patch estimate (the
//     brightest things are white), in linear light. Applied at WB_STRENGTH, because the glasses'
//     own camera already balances white and grey-world is fooled by a coloured wall. The raw
//     estimate's spread ("cast") says how tinted the light is, and is a reason to hedge.
//  3. The patch's pixels, balanced, go to OKLab and are split in two with k-means (k = 2). If the
//     smaller group is big enough and a different colour, it's two colours: "mostly white, with
//     blue" (stripes, a pattern, a logo). Otherwise the main group is the colour.
//  4. Naming: nearest everyday name (ColourPalette), with light/dark.
//  5. Hedging (Confidence): too dark or too much glare -> no colour at all; very dim light, a
//     very strong cast, or a muted colour under a cast -> "hard to tell in this light, it might
//     be..."; dim light, a cast, a muted colour, a colour between two families, a very dark and
//     muted object, or a busy pattern -> "probably ...". A confident name needs decent, near-white light and a clear
//     match. Thresholds are tuned on the JVM tests (synthetic frames) and are unverified on real
//     glasses (notes/light-and-colour.md).
// [ColourSpeech] turns the result into the spoken sentence. Pure Kotlin, JVM-tested.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.light

import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sqrt

enum class Confidence {
  /** Say the name plainly. */
  CONFIDENT,
  /** "Probably ...". */
  PROBABLE,
  /** "Hard to tell in this light. It might be ...". */
  UNSURE,
  /** Don't name a colour ("Too dark to tell"). */
  ABSTAIN,
}

/** Why the answer is hedged; each has a short spoken explanation (ColourSpeech). */
enum class HedgeReason {
  TOO_DARK, GLARE, VERY_DIM, DIM, WARM_LIGHT, COOL_LIGHT, TINTED_LIGHT, MUTED, BETWEEN, DARK_OBJECT, BUSY_PATTERN,
}

data class WhiteBalance(
    /** Gains applied to linear R, G, B (after strength). */
    val gainR: Double,
    val gainG: Double,
    val gainB: Double,
    /** Raw estimate's max gain / min gain: 1.0 = neutral light, 1.5 = clearly tinted. */
    val cast: Double,
    /** Raw blue gain / red gain: > 1 means the light is warm (yellow-orange). */
    val warmth: Double,
) {
  companion object {
    val NONE = WhiteBalance(1.0, 1.0, 1.0, 1.0, 1.0)
  }
}

/** One colour found in the patch. */
data class ColourPart(val match: ColourMatch, val share: Double, val swatch: Int)

data class ColourResult(
    val confidence: Confidence,
    /** The main colour (null when abstaining). */
    val main: ColourPart?,
    /** A second colour taking a good share of the patch, or null. */
    val second: ColourPart?,
    val reasons: List<HedgeReason>,
    val whiteBalance: WhiteBalance,
    /** Frame brightness, mean luma 0..255. */
    val frameLuma: Double,
    /** Main colour's swatch for the screen (ARGB), grey when abstaining. */
    val swatch: Int,
)

object ColourReader {

  /** Centre patch side as a fraction of the frame's width. */
  const val PATCH_FRACTION = 0.2

  /** The surround is outside the middle of the frame, this share of its width and height. */
  const val SURROUND_X = 0.6
  const val SURROUND_Y = 0.5

  /** How much of the estimated white-balance correction to apply. */
  const val WB_STRENGTH = 0.75

  private const val CLIP = 250
  private const val MAX_GAIN = 2.0

  fun read(pixels: IntArray, width: Int, height: Int): ColourResult {
    require(pixels.size == width * height && width >= 10 && height >= 10)
    val side = max(4, (width * PATCH_FRACTION).toInt())
    val cx = width / 2
    val cy = height / 2
    val x0 = cx - side / 2
    val y0 = cy - side / 2
    val mx = (width * SURROUND_X / 2).toInt()
    val my = (height * SURROUND_Y / 2).toInt()

    val frameLumas = IntArray(pixels.size) { ColourSpace.luma(pixels[it]) }
    val frameMean = frameLumas.average()
    val frameP95 = percentile(frameLumas, 0.95)

    // Surround pixels for white balance.
    val surround = ArrayList<Int>(pixels.size)
    for (y in 0 until height) for (x in 0 until width) {
      if (x in (cx - mx) until (cx + mx) && y in (cy - my) until (cy + my)) continue
      surround += pixels[y * width + x]
    }
    val wb = whiteBalance(surround)

    val patch = ArrayList<Int>(side * side)
    for (y in y0 until y0 + side) for (x in x0 until x0 + side) patch += pixels[y * width + x]
    val patchLumas = patch.map { ColourSpace.luma(it) }
    val patchMean = patchLumas.average()
    // Blown out to white (every channel), not just one saturated channel (a vivid red has R = 255).
    val clipped = patch.count { minChannel(it) >= CLIP }.toDouble() / patch.size

    val reasons = mutableListOf<HedgeReason>()
    if (frameP95 < 45 || frameMean < 15) return abstain(HedgeReason.TOO_DARK, wb, frameMean)
    if (clipped > 0.5) return abstain(HedgeReason.GLARE, wb, frameMean)

    // Balanced patch, in linear RGB and OKLab.
    val lin = patch.map {
      val c = ColourSpace.linear(it)
      LinearRgb(c.r * wb.gainR, c.g * wb.gainG, c.b * wb.gainB)
    }
    val labs = lin.map { ColourSpace.oklab(it) }
    var clusters = twoMeans(labs).sortedByDescending { it.size }
    fun part(cl: List<Int>): ColourPart {
      val mean = meanLab(cl.map { labs[it] })
      val swatch = ColourSpace.argb(meanLinear(cl.map { lin[it] }))
      return ColourPart(ColourPalette.nearest(mean), cl.size.toDouble() / labs.size, swatch)
    }
    var parts = clusters.map { part(it) }
    // Two groups that are really one colour (noise, shading): merge them back.
    if (parts.size == 2 &&
        (parts[0].match.colour.name == parts[1].match.colour.name ||
            parts[0].match.measured.distanceTo(parts[1].match.measured) <= MIN_SECOND_DISTANCE)) {
      clusters = listOf(labs.indices.toList())
      parts = listOf(part(clusters[0]))
    }
    val main = parts[0]
    // A small group (a speck, an edge, a logo) is left out of the main colour but not named.
    val second = parts.getOrNull(1)?.takeIf { it.share >= MIN_SECOND_SHARE }

    // Spread inside the main group: a busy pattern or a noisy, badly lit patch.
    val mainIdx = clusters[0]
    val centre = main.match.measured
    val spread = sqrt(mainIdx.sumOf { labs[it].distanceTo(centre).pow(2) } / mainIdx.size)

    var confidence = Confidence.CONFIDENT
    fun atMost(c: Confidence, r: HedgeReason) {
      if (c > confidence) confidence = c
      if (r !in reasons) reasons += r
    }
    val castReason =
        when {
          wb.warmth > 1.15 -> HedgeReason.WARM_LIGHT
          wb.warmth < 1 / 1.15 -> HedgeReason.COOL_LIGHT
          else -> HedgeReason.TINTED_LIGHT
        }
    val chroma = centre.chroma
    val chromatic = main.match.colour.family != ColourFamily.NEUTRAL

    if (frameMean < 35) atMost(Confidence.UNSURE, HedgeReason.VERY_DIM)
    else if (frameMean < 60) atMost(Confidence.PROBABLE, HedgeReason.DIM)
    if (wb.cast > 3.0) atMost(Confidence.UNSURE, castReason)
    else if (wb.cast > 1.5 && chroma < 0.10) atMost(Confidence.UNSURE, castReason)
    else if (wb.cast > 1.3) atMost(Confidence.PROBABLE, castReason)
    if (chromatic && chroma < 0.05) atMost(Confidence.PROBABLE, HedgeReason.MUTED)
    if (main.match.ambiguous) atMost(Confidence.PROBABLE, HedgeReason.BETWEEN)
    if (chromatic && patchMean < 30 && chroma < 0.1) atMost(Confidence.PROBABLE, HedgeReason.DARK_OBJECT)
    if (spread > 0.12) atMost(Confidence.PROBABLE, HedgeReason.BUSY_PATTERN)

    return ColourResult(confidence, main, second, reasons, wb, frameMean, main.swatch)
  }

  private const val MIN_SECOND_SHARE = 0.22
  private const val MIN_SECOND_DISTANCE = 0.12

  private fun abstain(reason: HedgeReason, wb: WhiteBalance, frameMean: Double) =
      ColourResult(Confidence.ABSTAIN, null, null, listOf(reason), wb, frameMean, ColourSpace.argb(60, 60, 60))

  /** Grey-world and white-patch estimates from [pixels], combined; see the header. */
  fun whiteBalance(pixels: List<Int>): WhiteBalance {
    val usable = pixels.filter { maxChannel(it) < CLIP && ColourSpace.luma(it) >= 12 }
    if (usable.size < 50) return WhiteBalance.NONE
    val lin = usable.map { ColourSpace.linear(it) }
    val grey = meanLinear(lin)
    val byLuma = usable.indices.sortedByDescending { ColourSpace.luma(usable[it]) }
    val top = byLuma.take(max(10, usable.size * 3 / 100)).map { lin[it] }
    val white = meanLinear(top)
    // Gains that make each estimate neutral, in log space so they combine and normalise cleanly.
    fun logGains(c: LinearRgb): DoubleArray {
      val e = 1e-4
      val m = (ln(c.r + e) + ln(c.g + e) + ln(c.b + e)) / 3
      return doubleArrayOf(m - ln(c.r + e), m - ln(c.g + e), m - ln(c.b + e))
    }
    val gw = logGains(grey)
    val wp = logGains(white)
    val raw = DoubleArray(3) { ((gw[it] + wp[it]) / 2).coerceIn(-ln(MAX_GAIN), ln(MAX_GAIN)) }
    val cast = exp(raw.max() - raw.min())
    val warmth = exp(raw[2] - raw[0])
    return WhiteBalance(
        exp(raw[0] * WB_STRENGTH), exp(raw[1] * WB_STRENGTH), exp(raw[2] * WB_STRENGTH), cast, warmth,
    )
  }

  /** Splits [labs] into at most two groups (indices). One group if they're all much the same. */
  fun twoMeans(labs: List<Oklab>): List<List<Int>> {
    if (labs.size < 4) return listOf(labs.indices.toList())
    val mean = meanLab(labs)
    val i1 = labs.indices.maxBy { labs[it].distanceTo(mean) }
    val i2 = labs.indices.maxBy { labs[it].distanceTo(labs[i1]) }
    if (labs[i1].distanceTo(labs[i2]) < 0.06) return listOf(labs.indices.toList())
    var c1 = labs[i1]
    var c2 = labs[i2]
    var assign = BooleanArray(labs.size)
    repeat(10) {
      val next = BooleanArray(labs.size) { labs[it].distanceTo(c2) < labs[it].distanceTo(c1) }
      val g1 = labs.indices.filter { !next[it] }
      val g2 = labs.indices.filter { next[it] }
      if (g1.isEmpty() || g2.isEmpty()) return listOf(labs.indices.toList())
      c1 = meanLab(g1.map { labs[it] })
      c2 = meanLab(g2.map { labs[it] })
      if (next.contentEquals(assign)) return listOf(g1, g2)
      assign = next
    }
    return listOf(labs.indices.filter { !assign[it] }, labs.indices.filter { assign[it] })
  }

  private fun meanLab(c: List<Oklab>): Oklab =
      Oklab(c.sumOf { it.l } / c.size, c.sumOf { it.a } / c.size, c.sumOf { it.b } / c.size)

  private fun meanLinear(c: List<LinearRgb>): LinearRgb =
      LinearRgb(c.sumOf { it.r } / c.size, c.sumOf { it.g } / c.size, c.sumOf { it.b } / c.size)

  private fun maxChannel(argb: Int): Int =
      max(ColourSpace.red(argb), max(ColourSpace.green(argb), ColourSpace.blue(argb)))

  private fun minChannel(argb: Int): Int =
      min(ColourSpace.red(argb), min(ColourSpace.green(argb), ColourSpace.blue(argb)))

  private fun percentile(values: IntArray, p: Double): Int {
    val sorted = values.sortedArray()
    return sorted[min(sorted.size - 1, (sorted.size * p).toInt())]
  }
}

/** The spoken answer for a [ColourResult]. English; the screen shows the same text. */
object ColourSpeech {

  fun describe(r: ColourResult): String {
    val main = r.main
    if (r.confidence == Confidence.ABSTAIN || main == null) {
      return when (r.reasons.firstOrNull()) {
        HedgeReason.GLARE -> "Too much glare to tell. Tilt it away from the light and say again."
        else -> "Too dark to tell. Turn a light on, or hold it nearer a window, and say again."
      }
    }
    val colours = colours(main, r.second)
    val sentence =
        when (r.confidence) {
          Confidence.CONFIDENT -> "${cap(colours)}."
          Confidence.PROBABLE -> {
            val alt =
                main.match.runnerUp?.takeIf { HedgeReason.BETWEEN in r.reasons && r.second == null }
            if (alt != null) "Probably $colours, or maybe ${alt.name}." else "Probably $colours."
          }
          else -> "Hard to tell in this light. It might be $colours."
        }
    val why = r.reasons.firstNotNullOfOrNull { reasonText(it) }
    return if (r.confidence != Confidence.CONFIDENT && why != null) "$sentence $why" else sentence
  }

  /** "navy blue", "mostly white, with blue", "white and blue". */
  fun colours(main: ColourPart, second: ColourPart?): String =
      when {
        second == null -> main.match.name
        main.share >= 0.6 -> "mostly ${main.match.name}, with ${second.match.name}"
        else -> "${main.match.name} and ${second.match.name}"
      }

  private fun reasonText(r: HedgeReason): String? =
      when (r) {
        HedgeReason.VERY_DIM, HedgeReason.DIM -> "The light is dim."
        HedgeReason.WARM_LIGHT -> "The light looks yellowish, which shifts colours."
        HedgeReason.COOL_LIGHT -> "The light looks bluish, which shifts colours."
        HedgeReason.TINTED_LIGHT -> "The light looks tinted."
        HedgeReason.MUTED -> "It's a muted colour."
        HedgeReason.DARK_OBJECT -> "It's very dark."
        HedgeReason.BUSY_PATTERN -> "It looks patterned."
        else -> null
      }

  private fun cap(s: String) = s.replaceFirstChar { it.uppercase() }
}
