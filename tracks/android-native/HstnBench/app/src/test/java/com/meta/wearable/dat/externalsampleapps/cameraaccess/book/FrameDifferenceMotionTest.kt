// FrameDifferenceMotionTest - the phone camera's page-turn motion score (notes/phone-camera.md)
//
// Grids are 32x24 cells of 0..255 brightness, as PhoneCamera makes them. A still page (with sensor
// noise or an exposure step) must score under PageTurnDetector's still threshold (0.1); a page
// sliding through view must score over its turn threshold (0.35); and a whole turn fed through the
// detector must end in a capture, as the frame-size score does on the glasses.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.book

import kotlin.random.Random
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FrameDifferenceMotionTest {

  private val cols = 32
  private val rows = 24
  private val detector = PageTurnDetector.Config()

  /** A page: light paper with dark text lines, shifted [shift] cells to the left. */
  private fun page(shift: Int = 0, brightness: Float = 0f, noise: Float = 0f, seed: Int = 1): FloatArray {
    val rnd = Random(seed)
    return FloatArray(cols * rows) { i ->
      val r = i / cols
      val c = (i % cols + shift).mod(cols)
      val ink = r % 3 == 1 && (c * 7 + r * 3) % 5 != 0
      val base = if (ink) 60f else 220f
      (base + brightness + (rnd.nextFloat() * 2f - 1f) * noise).coerceIn(0f, 255f)
    }
  }

  @Test
  fun theFirstGridHasNoScore() {
    val m = FrameDifferenceMotion()
    assertNull(m.onGrid(page()))
    assertEquals(0f, m.onGrid(page())!!, 0f)
  }

  @Test
  fun aStillPageWithSensorNoiseIsStill() {
    val m = FrameDifferenceMotion()
    m.onGrid(page(noise = 3f, seed = 1))
    for (seed in 2..20) {
      val score = m.onGrid(page(noise = 3f, seed = seed))!!
      assertTrue("noise scored $score", score < detector.stillThreshold)
    }
  }

  @Test
  fun anExposureStepIsNotMotion() {
    val m = FrameDifferenceMotion()
    m.onGrid(page())
    val score = m.onGrid(page(brightness = 30f))!!
    assertTrue("exposure step scored $score", score < detector.stillThreshold)
  }

  @Test
  fun aPageSlidingThroughViewIsATurn() {
    val m = FrameDifferenceMotion()
    m.onGrid(page(shift = 0))
    for (shift in listOf(3, 6, 9, 12)) {
      val score = m.onGrid(page(shift = shift))!!
      assertTrue("slide scored $score", score >= detector.turnThreshold)
    }
  }

  @Test
  fun aHandOverThePageIsATurnToo() {
    val m = FrameDifferenceMotion()
    m.onGrid(page())
    val hand = page().also { g -> for (i in 0 until g.size / 2) g[i] = 90f }
    assertTrue(m.onGrid(hand)!! >= detector.turnThreshold)
  }

  @Test
  fun aWholeTurnThroughTheDetectorCaptures() {
    val m = FrameDifferenceMotion()
    val d = PageTurnDetector()
    val frames =
        List(5) { page(noise = 2f, seed = it) } + // reading
            List(4) { page(shift = (it + 1) * 4, noise = 2f, seed = 10 + it) } + // turning
            List(8) { page(shift = 7, noise = 2f, seed = 20 + it) } // the new page, held still
    val events = frames.mapNotNull { m.onGrid(it) }.mapNotNull { d.onFrame(FrameSignal(it)) }
    assertEquals(TurnEvent.TurnStarted, events.first())
    assertEquals(TurnEvent.Capture(manual = false), events.last())
  }

  @Test
  fun aDifferentGridSizeStartsOver() {
    val m = FrameDifferenceMotion()
    m.onGrid(page())
    assertNull(m.onGrid(FloatArray(10)))
    m.reset()
    assertNull(m.onGrid(page()))
  }

  @Test
  fun lumaGridAveragesCellsAndRespectsTheRowStride() {
    // 64x48 picture, left half black, right half white, with 16 bytes of padding per row.
    val w = 64
    val h = 48
    val stride = w + 16
    val plane = ByteArray(stride * h) { i -> if (i % stride < w / 2) 0 else if (i % stride < w) 255.toByte() else 77 }
    val grid = FrameDifferenceMotion.lumaGrid({ plane[it].toInt() and 0xFF }, w, h, stride, cols = 4, rows = 2, step = 2)
    assertEquals(8, grid.size)
    for (r in 0 until 2) {
      assertEquals(0f, grid[r * 4 + 0], 0.01f)
      assertEquals(0f, grid[r * 4 + 1], 0.01f)
      assertEquals(255f, grid[r * 4 + 2], 0.01f)
      assertEquals(255f, grid[r * 4 + 3], 0.01f)
    }
  }
}
