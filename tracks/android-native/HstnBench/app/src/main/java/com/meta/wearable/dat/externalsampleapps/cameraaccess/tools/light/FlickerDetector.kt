// FlickerDetector - "It's blinking": a light in view going on and off
//
// An appliance LED blinking (a charger, a smoke alarm, a router) or a lamp flashing. The frame is cut
// into a grid of cells and each cell keeps its brightest pixel (so a small LED still moves its cell a
// lot) and its mean (to notice movement: a shifting scene changes many cells' means). Over the last
// few seconds, a cell is blinking if it switches between two clearly different levels, sitting near
// one or the other, at least [MIN_TRANSITIONS] times. Turning the head changes many cells' means at
// once (in both directions): that resets the history, so movement isn't mistaken for blinking, and a light
// switched on once isn't either (only one transition). At the probe's 4 frames a second it sees
// blinks up to about 1.5 a second; mains flicker (100/120 Hz) is far too fast for any frame rate the
// stream offers and isn't detected. Pure Kotlin (no Android imports), JVM-tested.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.light

import kotlin.math.abs
import kotlin.math.max

class FlickerDetector(
    private val cellsX: Int = 12,
    private val cellsY: Int = 20,
    /** Frames of history kept (5 s at 4 fps). */
    private val window: Int = 20,
) {
  private val history = ArrayDeque<IntArray>()
  private var lastMeans: IntArray? = null

  /** True while something in view is blinking. */
  var blinking = false
    private set

  /** Adds a frame; returns [blinking]. */
  fun update(pixels: IntArray, width: Int, height: Int): Boolean {
    val (maxes, means) = cells(pixels, width, height)
    return updateCells(maxes, means)
  }

  /**
   * Adds one frame's cells (row-major, [cellsX] x [cellsY]): brightest luma and mean luma per
   * cell. Returns [blinking].
   */
  fun updateCells(cells: IntArray, means: IntArray = cells): Boolean {
    require(cells.size == cellsX * cellsY && means.size == cells.size)
    val last = lastMeans
    lastMeans = means
    if (last != null) {
      val changed = means.indices.filter { abs(means[it] - last[it]) > MOTION_DELTA }
      val brighter = changed.count { means[it] > last[it] }
      // Most cells changing the same way is the room light itself going on or off, not movement.
      val sameWay = max(brighter, changed.size - brighter) >= changed.size * 0.9
      if (changed.size > cells.size * MOTION_SHARE && !sameWay) {
        // The view moved (or the whole scene changed): start again from here.
        history.clear()
      }
    }
    history.addLast(cells)
    while (history.size > window) history.removeFirst()
    blinking = history.size >= MIN_FRAMES && cells.indices.any { cellBlinks(it) }
    return blinking
  }

  fun reset() {
    history.clear()
    lastMeans = null
    blinking = false
  }

  private fun cellBlinks(i: Int): Boolean {
    val series = history.map { it[i] }
    val lo = series.min()
    val hi = series.max()
    val amp = hi - lo
    if (amp < MIN_AMPLITUDE || hi < MIN_ON) return false
    // Values must sit near the two levels, not drift between them.
    val band = amp * 0.3
    if (series.count { it - lo <= band || hi - it <= band } < series.size * 0.8) return false
    val mid = (lo + hi) / 2
    var transitions = 0
    var state = series[0] > mid
    for (v in series) {
      val s = if (state) v > mid - band / 2 else v > mid + band / 2
      if (s != state) {
        transitions++
        state = s
      }
    }
    return transitions >= MIN_TRANSITIONS
  }

  /** Brightest and mean luma in each cell. */
  fun cells(pixels: IntArray, width: Int, height: Int): Pair<IntArray, IntArray> {
    val maxes = IntArray(cellsX * cellsY)
    val sums = IntArray(cellsX * cellsY)
    val counts = IntArray(cellsX * cellsY)
    for (y in 0 until height) {
      val cy = (y * cellsY / height).coerceAtMost(cellsY - 1)
      for (x in 0 until width) {
        val cx = (x * cellsX / width).coerceAtMost(cellsX - 1)
        val k = cy * cellsX + cx
        val l = ColourSpace.luma(pixels[y * width + x])
        maxes[k] = max(maxes[k], l)
        sums[k] += l
        counts[k]++
      }
    }
    return maxes to IntArray(sums.size) { sums[it] / max(1, counts[it]) }
  }

  companion object {
    const val MIN_FRAMES = 6
    const val MIN_TRANSITIONS = 3
    const val MIN_AMPLITUDE = 60
    const val MIN_ON = 110
    const val MOTION_DELTA = 25
    const val MOTION_SHARE = 0.3
  }
}
