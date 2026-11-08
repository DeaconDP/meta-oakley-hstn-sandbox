// LightFixtures - synthetic camera frames for the light and colour tests
//
// Frames are packed ARGB pixel arrays the size the tool samples (160x288 for colour, 96x172 for the
// probe): a surround (the room) with an object in the middle, optionally striped, then optionally
// lit by a coloured light (each channel scaled in linear light, as a warm bulb would) and given a
// little deterministic noise like a compressed camera stream.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.light

import kotlin.random.Random

object LightFixtures {
  const val W = 160
  const val H = 288

  data class Rgb(val r: Int, val g: Int, val b: Int)

  /** Warm tungsten-like light: less blue, a bit less green. */
  val WARM = Triple(1.0, 0.78, 0.48)
  val VERY_WARM = Triple(1.0, 0.62, 0.28)

  /**
   * [surround] room, a square object of [objectFraction] x width in the middle in [colour] (or
   * vertical stripes of [colour] and [stripe], [stripeShare] of each period being [stripe]).
   */
  fun frame(
      colour: Rgb,
      surround: Rgb = Rgb(128, 128, 128),
      objectFraction: Double = 0.4,
      stripe: Rgb? = null,
      stripeShare: Double = 0.3,
      light: Triple<Double, Double, Double>? = null,
      exposure: Double = 1.0,
      noise: Int = 3,
      w: Int = W,
      h: Int = H,
      seed: Int = 1,
  ): IntArray {
    val rnd = Random(seed)
    val side = (w * objectFraction).toInt()
    val x0 = w / 2 - side / 2
    val y0 = h / 2 - side / 2
    val period = 10
    return IntArray(w * h) { i ->
      val x = i % w
      val y = i / w
      val inside = x in x0 until x0 + side && y in y0 until y0 + side
      val c =
          when {
            !inside -> surround
            stripe != null && ((x - x0) % period) < period * stripeShare -> stripe
            else -> colour
          }
      lit(c, light, exposure, if (noise > 0) rnd.nextInt(-noise, noise + 1) else 0)
    }
  }

  fun uniform(c: Rgb, w: Int = 96, h: Int = 172): IntArray = IntArray(w * h) { ColourSpace.argb(c.r, c.g, c.b) }

  private fun lit(c: Rgb, light: Triple<Double, Double, Double>?, exposure: Double, n: Int): Int {
    fun ch(v: Int, k: Double): Int = ColourSpace.toSrgb(ColourSpace.toLinear(v) * k * exposure) + n
    val l = light ?: Triple(1.0, 1.0, 1.0)
    return ColourSpace.argb(ch(c.r, l.first), ch(c.g, l.second), ch(c.b, l.third))
  }

  fun read(frame: IntArray): ColourResult = ColourReader.read(frame, W, H)
}
