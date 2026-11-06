// BarcodeHint - is there something barcode-like in the frame, and how big and central is it?
//
// While searching, the label reader plays geiger-style ticks that get faster and higher as a
// barcode-like patch gets bigger and nearer the middle, so the user can turn the packet towards it
// before ML Kit can decode it. A barcode is many dark/light changes along a row that repeat almost
// exactly in rows above and below (the bars are vertical). Text also has many changes along a row,
// but a row a few percent of the frame lower looks different. The caller passes full-width rows
// (bars are only a few pixels wide) sampled at even heights. Cheap: a few dozen rows per frame, no
// allocation beyond one array per row. Pure Kotlin, JVM-tested.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.labels

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.sqrt

/** A barcode-like patch, as fractions of the frame (0..1). */
data class BarRegion(val left: Float, val right: Float, val top: Float, val bottom: Float) {
  val width: Float
    get() = right - left

  val centerX: Float
    get() = (left + right) / 2f

  val centerY: Float
    get() = (top + bottom) / 2f

  /**
   * 0..1: how big and central the patch is. A barcode a third of the frame wide in the middle is
   * about 0.6; one filling half the width, centred, is 1.
   */
  val closeness: Float
    get() {
      val size = (width / 0.5f).coerceIn(0f, 1f)
      val off = max(abs(centerX - 0.5f), abs(centerY - 0.5f)) * 2f
      return (sqrt(size) * (1f - 0.6f * off.coerceIn(0f, 1f))).coerceIn(0f, 1f)
    }
}

object BarcodeHint {

  /** Fewest dark/light changes in a run for a row to look like bars (EAN-13 has 58). */
  private const val MIN_TRANSITIONS = 18
  /** Rows compared with the row this many samples below. */
  private const val ROW_STEP = 2
  /** Fraction of pixels that must match between the two rows. */
  private const val MIN_AGREEMENT = 0.85f

  /**
   * [luma] is [rows] rows of [width] brightness values (0..255), evenly spaced from top to bottom
   * of the frame. Returns the biggest barcode-like patch, or null.
   */
  fun find(luma: IntArray, width: Int, rows: Int): BarRegion? {
    require(luma.size == width * rows && width >= 32 && rows >= ROW_STEP + 2)
    val bits = Array(rows) { r -> binarize(luma, r * width, width) }
    val spans = arrayOfNulls<IntArray>(rows)
    for (r in 0 until rows) spans[r] = barSpan(bits[r], width)

    // A row counts if it has a bar span that the row ROW_STEP below repeats.
    val good = BooleanArray(rows)
    for (r in 0 until rows - ROW_STEP) {
      val s = spans[r] ?: continue
      if (agreement(bits[r], bits[r + ROW_STEP], s[0], s[1]) >= MIN_AGREEMENT) good[r] = true
    }
    // The biggest group of consecutive good rows (one missing row allowed).
    var best: BarRegion? = null
    var bestArea = 0f
    var r = 0
    while (r < rows) {
      if (!good[r]) {
        r++
        continue
      }
      var end = r
      var left = spans[r]!![0]
      var right = spans[r]!![1]
      var k = r + 1
      while (k < rows && (good[k] || (k + 1 < rows && good[k + 1]))) {
        if (good[k]) {
          end = k
          left = minOf(left, spans[k]!![0])
          right = maxOf(right, spans[k]!![1])
        }
        k++
      }
      val region =
          BarRegion(
              left / width.toFloat(),
              (right + 1) / width.toFloat(),
              r / rows.toFloat(),
              (end + ROW_STEP + 1) / rows.toFloat(),
          )
      val area = region.width * (region.bottom - region.top)
      if (area > bestArea) {
        bestArea = area
        best = region
      }
      r = k
    }
    return best
  }

  /** Dark (true) / light per pixel, against a moving average, so uneven lighting doesn't matter. */
  private fun binarize(luma: IntArray, offset: Int, width: Int): BooleanArray {
    val half = 12
    val prefix = IntArray(width + 1)
    for (x in 0 until width) prefix[x + 1] = prefix[x] + luma[offset + x]
    var min = 255
    var maxV = 0
    for (x in 0 until width) {
      min = minOf(min, luma[offset + x])
      maxV = maxOf(maxV, luma[offset + x])
    }
    val flat = maxV - min < 40
    return BooleanArray(width) { x ->
      if (flat) return@BooleanArray false
      val a = maxOf(0, x - half)
      val b = minOf(width, x + half + 1)
      val mean = (prefix[b] - prefix[a]) / (b - a)
      luma[offset + x] < mean - 8
    }
  }

  /** The longest run of closely spaced changes in a row, as [start, end] pixels, or null. */
  private fun barSpan(bits: BooleanArray, width: Int): IntArray? {
    val maxGap = maxOf(6, width / 24)
    var bestStart = -1
    var bestEnd = -1
    var bestCount = 0
    var runStart = -1
    var last = -1
    var count = 0
    for (x in 1 until width) {
      if (bits[x] == bits[x - 1]) continue
      if (last >= 0 && x - last <= maxGap) {
        count++
      } else {
        runStart = x
        count = 1
      }
      last = x
      if (count > bestCount) {
        bestCount = count
        bestStart = runStart
        bestEnd = x
      }
    }
    if (bestCount < MIN_TRANSITIONS || bestEnd - bestStart < width / 8) return null
    return intArrayOf(bestStart, bestEnd)
  }

  private fun agreement(a: BooleanArray, b: BooleanArray, from: Int, to: Int): Float {
    var same = 0
    for (x in from..to) if (a[x] == b[x]) same++
    return same / (to - from + 1).toFloat()
  }
}
