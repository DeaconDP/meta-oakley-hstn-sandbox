// ImageCheck - is there anything readable in the photo at all?
//
// OCR takes seconds (16-19 s on the emulator). When the lens is covered, the room is dark, the page
// is washed out by glare, or a hand is over half the page, the user should hear why within a
// moment, not after OCR comes back empty. This looks only at brightness on a coarse grid of luma
// samples, so it's instant and pure (the Android side samples the bitmap).
//
// Thresholds assume a printed page: light paper, dark ink. A page fills a good part of the frame
// when the user is ~25-40 cm away (notes/book-reader.md > Experiment result).

package com.meta.wearable.dat.externalsampleapps.cameraaccess.book

import kotlin.math.sqrt

enum class ImageIssue(val blocksOcr: Boolean) {
  /** Almost black and flat: something is over the lens (a finger, hair, a hat brim). */
  COVERED(true),
  /** Too dark to make out print. */
  TOO_DARK(true),
  /** Flat and featureless, but not dark: a wall, a table, the ceiling. No page in view. */
  NOTHING_IN_VIEW(true),
  /** Much of the frame blown out to white: light reflecting off glossy paper. */
  GLARE(false),
  /** One part of the frame much darker than the rest: a hand or thumb over the page. */
  PARTLY_BLOCKED(false),
}

object ImageCheck {

  /**
   * [luma] is row-major 0..255 brightness, [width] x [height] **point** samples (not block
   * averages: a point lands on ink or on paper, so a page of print varies strongly while a wall
   * doesn't). A 48x72 grid is plenty. Returns the most serious issue, or null if the image could
   * hold a readable page.
   */
  fun check(luma: IntArray, width: Int, height: Int): ImageIssue? {
    require(luma.size == width * height && width >= 4 && height >= 4)
    val n = luma.size
    val mean = luma.average()
    val sd = sqrt(luma.sumOf { (it - mean) * (it - mean) } / n)
    // Paper is the brightest thing in a page photo; if even the top 5% is dim, there's no
    // readable paper (a small page on a dark table still passes).
    val p95 = luma.sorted()[(n * 0.95).toInt().coerceAtMost(n - 1)]

    if (p95 < 30) return ImageIssue.COVERED
    if (p95 < 85) return ImageIssue.TOO_DARK
    if (sd < 10) return ImageIssue.NOTHING_IN_VIEW

    val saturated = luma.count { it >= 250 }.toDouble() / n
    if (saturated > 0.25) return ImageIssue.GLARE

    // Compare the four quadrants and the two halves: an obstruction is a big, dark, flat region
    // next to a bright one.
    val regions = regions(luma, width, height)
    val brightest = regions.maxOf { it.mean }
    val blocked =
        regions.any { r -> r.mean < 70 && r.mean < brightest * 0.45 && r.sd < 30 }
    if (blocked) return ImageIssue.PARTLY_BLOCKED
    return null
  }

  /**
   * After OCR asked for a better frame: should the image issue explain it instead? Only when OCR
   * found no usable text. If the text is just cut off or small, the framing hint ("turn your head
   * right", "closer") is more specific, and a page on a dark table can look "partly blocked".
   */
  fun explainsFramingFailure(issue: ImageIssue?, framing: List<FramingIssue>): Boolean =
      issue != null &&
          framing.all { it == FramingIssue.NO_TEXT || it == FramingIssue.LOW_CONFIDENCE }

  private class Region(val mean: Double, val sd: Double)

  private fun regions(luma: IntArray, w: Int, h: Int): List<Region> {
    val hw = w / 2
    val hh = h / 2
    val boxes =
        listOf(
            intArrayOf(0, 0, hw, hh), intArrayOf(hw, 0, w, hh),
            intArrayOf(0, hh, hw, h), intArrayOf(hw, hh, w, h),
            intArrayOf(0, 0, hw, h), intArrayOf(hw, 0, w, h),
            intArrayOf(0, 0, w, hh), intArrayOf(0, hh, w, h),
        )
    return boxes.map { (x0, y0, x1, y1) ->
      var sum = 0.0
      var count = 0
      for (y in y0 until y1) for (x in x0 until x1) {
        sum += luma[y * w + x]
        count++
      }
      val m = sum / count
      var v = 0.0
      for (y in y0 until y1) for (x in x0 until x1) {
        val d = luma[y * w + x] - m
        v += d * d
      }
      Region(m, sqrt(v / count))
    }
  }
}
