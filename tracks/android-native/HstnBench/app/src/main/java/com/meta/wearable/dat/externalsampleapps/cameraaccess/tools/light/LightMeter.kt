// LightMeter - how bright the view is, and the probe tone's pitch for it
//
// The light probe answers "is the light on?", "are the curtains open?" and "where's the window?"
// with a tone whose pitch follows brightness as the user turns their head. This file is the
// arithmetic, on a downscaled frame of packed ARGB pixels:
//  - [measure]: centre-weighted brightness in linear light (the middle half of the frame counts
//    three times, so the tone points where the head points), mean luma, the share of blown-out
//    pixels, and which third (left, middle, right) is brightest.
//  - [PitchMap]: brightness -> frequency, logarithmic both ways. Perceived brightness is roughly
//    log luminance and perceived pitch is log frequency, so each doubling of light (one camera
//    "stop") raises the tone by the same musical interval: 9 stops span 3 octaves, 220-1760 Hz.
//  - [PitchSmoother]: an exponential average in that log space with a small dead band, so camera
//    noise and compression flicker don't make the tone warble.
//  - [level]: dark / dim / normal indoor / bright / very bright. The camera's auto-exposure scales
//    every frame towards mid-grey, and DAT 1.0.1 exposes no exposure or ISO for a frame, so these
//    are relative to what the camera chose, not lux, and the spoken level says so.
// Pure Kotlin (no Android imports), JVM-tested.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.light

import kotlin.math.abs
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.pow

enum class LightLevel(val spoken: String) {
  DARK("Dark"),
  DIM("Dim"),
  NORMAL("Normal indoor light"),
  BRIGHT("Bright"),
  VERY_BRIGHT("Very bright"),
}

enum class Side { LEFT, MIDDLE, RIGHT }

data class LightReading(
    /** Centre-weighted relative luminance, linear 0..1. What the tone follows. */
    val luminance: Double,
    /** Whole-frame mean luma 0..255 (gamma-encoded, as the camera delivers it). */
    val meanLuma: Double,
    /** Share of pixels with a channel at 250+: a lamp, a window, the sun. */
    val clipped: Double,
    /** The clearly brightest third of the view, or null if they're about even. */
    val brightestSide: Side?,
)

object LightMeter {

  fun measure(pixels: IntArray, width: Int, height: Int): LightReading {
    require(pixels.size == width * height && width >= 3 && height >= 3)
    var weighted = 0.0
    var weights = 0.0
    var lumaSum = 0L
    var clipped = 0
    val thirds = DoubleArray(3)
    val thirdCounts = IntArray(3)
    for (y in 0 until height) {
      val midY = y >= height / 4 && y < height * 3 / 4
      for (x in 0 until width) {
        val p = pixels[y * width + x]
        val lum = ColourSpace.luminance(p)
        val w = if (midY && x >= width / 4 && x < width * 3 / 4) 3.0 else 1.0
        weighted += lum * w
        weights += w
        lumaSum += ColourSpace.luma(p)
        if (ColourSpace.red(p) >= 250 || ColourSpace.green(p) >= 250 || ColourSpace.blue(p) >= 250) clipped++
        val t = (x * 3 / width).coerceIn(0, 2)
        thirds[t] += lum
        thirdCounts[t]++
      }
    }
    val means = DoubleArray(3) { thirds[it] / max(1, thirdCounts[it]) }
    val best = means.indices.maxBy { means[it] }
    val others = means.indices.filter { it != best }.maxOf { means[it] }
    val side = if (means[best] > 0.02 && means[best] > others * 1.6) Side.entries[best] else null
    return LightReading(weighted / weights, lumaSum.toDouble() / pixels.size, clipped.toDouble() / pixels.size, side)
  }

  /** The spoken level for a reading; see the header for why it's relative. */
  fun level(r: LightReading): LightLevel =
      when {
        r.meanLuma < 20 -> LightLevel.DARK
        r.meanLuma < 60 -> LightLevel.DIM
        r.meanLuma >= 200 || r.clipped > 0.3 -> LightLevel.VERY_BRIGHT
        r.meanLuma >= 150 -> LightLevel.BRIGHT
        else -> LightLevel.NORMAL
      }
}

object PitchMap {
  const val MIN_HZ = 220f
  const val MAX_HZ = 1760f
  /** Darkest luminance with its own pitch: 9 stops below white. */
  const val FLOOR = 1.0 / 512

  /** 0 (dark) .. 1 (white), linear in stops. */
  fun position(luminance: Double): Double {
    val l = luminance.coerceIn(FLOOR, 1.0)
    return (ln(l) - ln(FLOOR)) / -ln(FLOOR)
  }

  /** Frequency for a [position], exponential so equal steps sound equal. */
  fun frequency(position: Double): Float =
      (MIN_HZ * (MAX_HZ / MIN_HZ).toDouble().pow(position.coerceIn(0.0, 1.0))).toFloat()

  fun frequencyFor(luminance: Double): Float = frequency(position(luminance))
}

/**
 * Smooths the tone's position (0..1). [alpha] is how far each update moves towards the new value:
 * 0.4 at 4 updates a second settles in about a second. Changes smaller than [deadBand] are ignored.
 */
class PitchSmoother(private val alpha: Double = 0.4, private val deadBand: Double = 0.004) {
  var position: Double? = null
    private set

  fun update(target: Double): Double {
    val p = position
    val next = if (p == null) target else p + alpha * (target - p)
    if (p == null || abs(next - p) >= deadBand) position = next
    return position!!
  }

  fun reset() {
    position = null
  }
}
