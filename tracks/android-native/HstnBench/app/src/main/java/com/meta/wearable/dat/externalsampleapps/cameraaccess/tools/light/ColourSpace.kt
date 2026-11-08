// ColourSpace - turning camera pixels into numbers that match how people see colour
//
// Camera pixels are sRGB: gamma-encoded, and equal steps in them are not equal steps to the eye.
// Everything the light tool measures goes through here: sRGB 0..255 -> linear light (for brightness
// and white balance, which are physical) -> OKLab (for naming colours, which is perceptual: equal
// distances look about equally different, and lightness, chroma and hue are separate axes).
// OKLab is Björn Ottosson's 2020 space; it fixes CIELAB's blue-to-purple hue drift, which matters
// for "navy" vs "purple". Pixels are packed ARGB ints, as Android's Bitmap.getPixels gives them.
// Pure Kotlin (no Android imports), JVM-tested.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.light

import kotlin.math.atan2
import kotlin.math.cbrt
import kotlin.math.pow
import kotlin.math.sqrt

/** A colour in OKLab. [l] is lightness 0..1; [a] green-red and [b] blue-yellow, about -0.4..0.4. */
data class Oklab(val l: Double, val a: Double, val b: Double) {
  /** Colourfulness: 0 for greys, ~0.1 for muted colours, 0.2-0.3 for vivid ones. */
  val chroma: Double
    get() = sqrt(a * a + b * b)

  /** Hue angle in degrees, 0..360 (red ~30, yellow ~110, green ~140, blue ~265). */
  val hue: Double
    get() = (Math.toDegrees(atan2(b, a)) + 360.0) % 360.0

  fun distanceTo(o: Oklab, lightnessWeight: Double = 1.0): Double {
    val dl = (l - o.l) * lightnessWeight
    val da = a - o.a
    val db = b - o.b
    return sqrt(dl * dl + da * da + db * db)
  }
}

/** Linear-light RGB, each 0..1 (more than 1 after a white-balance gain; clamp before encoding). */
data class LinearRgb(val r: Double, val g: Double, val b: Double)

object ColourSpace {

  private val TO_LINEAR = DoubleArray(256) { i ->
    val c = i / 255.0
    if (c <= 0.04045) c / 12.92 else ((c + 0.055) / 1.055).pow(2.4)
  }

  fun red(argb: Int): Int = (argb shr 16) and 0xFF

  fun green(argb: Int): Int = (argb shr 8) and 0xFF

  fun blue(argb: Int): Int = argb and 0xFF

  fun argb(r: Int, g: Int, b: Int): Int =
      (0xFF shl 24) or (r.coerceIn(0, 255) shl 16) or (g.coerceIn(0, 255) shl 8) or b.coerceIn(0, 255)

  /** sRGB 0..255 to linear light 0..1. */
  fun toLinear(channel: Int): Double = TO_LINEAR[channel.coerceIn(0, 255)]

  /** Linear 0..1 back to sRGB 0..255 (clamped). */
  fun toSrgb(linear: Double): Int {
    val c = linear.coerceIn(0.0, 1.0)
    val s = if (c <= 0.0031308) c * 12.92 else 1.055 * c.pow(1 / 2.4) - 0.055
    return (s * 255.0 + 0.5).toInt().coerceIn(0, 255)
  }

  fun linear(argb: Int): LinearRgb = LinearRgb(toLinear(red(argb)), toLinear(green(argb)), toLinear(blue(argb)))

  /** Gamma-encoded brightness 0..255 (Rec. 709 weights on the sRGB values), as a camera "luma". */
  fun luma(argb: Int): Int = (0.2126 * red(argb) + 0.7152 * green(argb) + 0.0722 * blue(argb) + 0.5).toInt()

  /** Relative luminance 0..1 (linear light), the physical brightness. */
  fun luminance(argb: Int): Double =
      0.2126 * toLinear(red(argb)) + 0.7152 * toLinear(green(argb)) + 0.0722 * toLinear(blue(argb))

  fun oklab(c: LinearRgb): Oklab {
    val r = c.r.coerceIn(0.0, 1.0)
    val g = c.g.coerceIn(0.0, 1.0)
    val b = c.b.coerceIn(0.0, 1.0)
    val l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
    val m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
    val s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
    return Oklab(
        0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
        1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
        0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
    )
  }

  fun oklab(argb: Int): Oklab = oklab(linear(argb))

  fun oklab(r: Int, g: Int, b: Int): Oklab = oklab(argb(r, g, b))

  /** Linear RGB back to a packed sRGB colour (for the on-screen swatch). */
  fun argb(c: LinearRgb): Int = argb(toSrgb(c.r), toSrgb(c.g), toSrgb(c.b))
}
