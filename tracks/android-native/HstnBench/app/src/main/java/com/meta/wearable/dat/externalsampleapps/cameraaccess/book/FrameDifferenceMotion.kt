// FrameDifferenceMotion - a page-turn motion score from small luma grids (the phone camera)
//
// The glasses stream compressed HEVC, so their motion signal is the P-frame size (FrameSizeMotion).
// The phone camera hands us raw pictures instead, so PhoneCamera averages each analysed frame into
// a small grid of brightness cells (lumaGrid) and this compares consecutive grids. The score is the
// mean absolute cell difference after taking out the change in overall brightness (auto exposure
// steps would otherwise look like motion), minus a noise floor, scaled to 0..1. It feeds the same
// PageTurnDetector: with the defaults a page sliding through view scores well over its turn
// threshold (0.35) and a phone held still scores under its still threshold (0.1).
// Pure Kotlin, JVM-tested (FrameDifferenceMotionTest).

package com.meta.wearable.dat.externalsampleapps.cameraaccess.book

import kotlin.math.abs

class FrameDifferenceMotion(
    /** Mean cell difference (0..255 levels) that counts as no motion: sensor noise, hand tremor. */
    private val noiseFloor: Float = 2.5f,
    /** Mean difference above the floor that scores 1.0. */
    private val scale: Float = 20f,
) {
  private var previous: FloatArray? = null

  /** Returns 0..1, or null for the first grid (or a grid of a different size, which restarts). */
  fun onGrid(grid: FloatArray): Float? {
    val prev = previous
    previous = grid.copyOf()
    if (prev == null || prev.size != grid.size || grid.isEmpty()) return null
    val shift = grid.average().toFloat() - prev.average().toFloat()
    var sum = 0f
    for (i in grid.indices) sum += abs(grid[i] - prev[i] - shift)
    val mean = sum / grid.size
    return ((mean - noiseFloor) / scale).coerceIn(0f, 1f)
  }

  fun reset() {
    previous = null
  }

  companion object {
    /**
     * Averages a luma plane (0..255 per pixel, row-major, [rowStride] bytes per row) into a
     * [cols] x [rows] grid, reading every [step]th pixel in each cell. Cheap: a 640x480 frame at
     * 32x24 with step 4 reads about 19 thousand pixels.
     */
    fun lumaGrid(
        luma: (Int) -> Int,
        width: Int,
        height: Int,
        rowStride: Int,
        cols: Int = 32,
        rows: Int = 24,
        step: Int = 4,
    ): FloatArray {
      val out = FloatArray(cols * rows)
      val cellW = width / cols
      val cellH = height / rows
      if (cellW <= 0 || cellH <= 0) return out
      for (r in 0 until rows) {
        for (c in 0 until cols) {
          var sum = 0
          var n = 0
          var y = r * cellH
          while (y < (r + 1) * cellH) {
            var x = c * cellW
            val base = y * rowStride
            while (x < (c + 1) * cellW) {
              sum += luma(base + x)
              n++
              x += step
            }
            y += step
          }
          out[r * cols + c] = if (n == 0) 0f else sum.toFloat() / n
        }
      }
      return out
    }
  }
}
