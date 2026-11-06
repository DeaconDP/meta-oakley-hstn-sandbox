// LightProbeTest - brightness, the probe's log pitch and smoothing, levels, direction, blinking,
// and the light tool's grammar.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.light

import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.GlobalCommand
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.GlobalGrammar
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.Phrases
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolRequest
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.light.LightFixtures.Rgb
import kotlin.math.abs
import kotlin.math.ln
import kotlin.random.Random
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LightProbeTest {

  private val w = 96
  private val h = 172

  private fun grey(v: Int) = LightFixtures.uniform(Rgb(v, v, v), w, h)

  private fun reading(v: Int) = LightMeter.measure(grey(v), w, h)

  @Test
  fun pitchRisesMonotonicallyWithBrightness() {
    var last = 0f
    for (v in 0..255) {
      val hz = PitchMap.frequencyFor(reading(v).luminance)
      assertTrue("$v: $hz < $last", hz >= last)
      last = hz
    }
    assertEquals(PitchMap.MIN_HZ, PitchMap.frequencyFor(0.0), 0.01f)
    assertEquals(PitchMap.MAX_HZ, PitchMap.frequencyFor(1.0), 0.01f)
    // Strictly rising above the floor.
    assertTrue(PitchMap.frequencyFor(0.01) < PitchMap.frequencyFor(0.02))
  }

  @Test
  fun pitchIsLogarithmicEachDoublingOfLightIsTheSameInterval() {
    val ratios = listOf(0.004, 0.01, 0.05, 0.2).map { PitchMap.frequencyFor(it * 2) / PitchMap.frequencyFor(it) }
    // 9 stops over 3 octaves: a stop is a third of an octave, 2^(1/3).
    for (r in ratios) assertEquals(Math.cbrt(2.0), r.toDouble(), 0.001)
  }

  @Test
  fun smoothingSettlesWithoutOvershootAndIgnoresNoise() {
    val s = PitchSmoother()
    s.update(0.2)
    var p = 0.2
    val seen = mutableListOf<Double>()
    repeat(12) {
      p = s.update(0.8)
      seen += p
    }
    assertTrue("rising: $seen", seen.zipWithNext().all { (a, b) -> b >= a })
    assertTrue("no overshoot: $seen", seen.all { it <= 0.8 })
    assertTrue("settled: $p", abs(p - 0.8) < 0.01)
    // Noise of +-0.03 around 0.5 (compression flicker) moves the tone far less.
    val s2 = PitchSmoother()
    val rnd = Random(7)
    s2.update(0.5)
    val input = (0 until 60).map { 0.5 + rnd.nextDouble(-0.03, 0.03) }
    val out = input.map { s2.update(it) }
    val spread = out.max() - out.min()
    assertTrue("spread $spread", spread < 0.6 * (input.max() - input.min()))
    // A tiny change inside the dead band doesn't move it at all.
    val s3 = PitchSmoother()
    s3.update(0.5)
    assertEquals(0.5, s3.update(0.505), 1e-9)
  }

  @Test
  fun levelsFromDarkToVeryBright() {
    assertEquals(LightLevel.DARK, LightMeter.level(reading(10)))
    assertEquals(LightLevel.DIM, LightMeter.level(reading(40)))
    assertEquals(LightLevel.NORMAL, LightMeter.level(reading(120)))
    assertEquals(LightLevel.BRIGHT, LightMeter.level(reading(170)))
    assertEquals(LightLevel.VERY_BRIGHT, LightMeter.level(reading(230)))
    // A blown-out window filling a third of the view is very bright even if the rest is normal.
    val px = grey(100)
    for (i in 0 until px.size * 2 / 5) px[i] = ColourSpace.argb(255, 255, 255)
    assertEquals(LightLevel.VERY_BRIGHT, LightMeter.level(LightMeter.measure(px, w, h)))
  }

  @Test
  fun centreCountsMoreThanTheEdges() {
    // Bright centre, dark edges reads brighter than bright edges, dark centre.
    val centre = IntArray(w * h) { i ->
      val x = i % w
      val y = i / w
      val mid = x in w / 4 until w * 3 / 4 && y in h / 4 until h * 3 / 4
      if (mid) ColourSpace.argb(200, 200, 200) else ColourSpace.argb(30, 30, 30)
    }
    val edges = IntArray(w * h) { i -> if (centre[i] == ColourSpace.argb(200, 200, 200)) ColourSpace.argb(30, 30, 30) else ColourSpace.argb(200, 200, 200) }
    assertTrue(LightMeter.measure(centre, w, h).luminance > LightMeter.measure(edges, w, h).luminance)
  }

  @Test
  fun brightestSide() {
    fun scene(third: Int) = IntArray(w * h) { i -> if ((i % w) * 3 / w == third) ColourSpace.argb(230, 230, 230) else ColourSpace.argb(40, 40, 40) }
    assertEquals(Side.LEFT, LightMeter.measure(scene(0), w, h).brightestSide)
    assertEquals(Side.MIDDLE, LightMeter.measure(scene(1), w, h).brightestSide)
    assertEquals(Side.RIGHT, LightMeter.measure(scene(2), w, h).brightestSide)
    assertNull(reading(120).brightestSide)
  }

  // MARK: - Blinking

  /** A dim room with a small LED at (60, 40) that's on in frames where [on] is true. */
  private fun led(on: Boolean, seed: Int, ledSize: Int = 3): IntArray {
    val rnd = Random(seed)
    return IntArray(w * h) { i ->
      val x = i % w
      val y = i / w
      val base = 50 + (x / 12) * 3 + rnd.nextInt(-4, 5)
      val v = if (on && x in 60 until 60 + ledSize && y in 40 until 40 + ledSize) 240 else base
      ColourSpace.argb(v, v, v)
    }
  }

  @Test
  fun blinkingLedIsDetected() {
    val f = FlickerDetector()
    var detectedAt = -1
    // On for 2 frames, off for 2 (1 Hz at 4 fps).
    for (n in 0 until 20) {
      if (f.update(led(on = (n / 2) % 2 == 0, seed = n), w, h) && detectedAt < 0) detectedAt = n
    }
    assertTrue("detected at $detectedAt", detectedAt in 5..10)
    assertTrue(f.blinking)
  }

  @Test
  fun fastBlinkEveryFrameIsDetected() {
    val f = FlickerDetector()
    repeat(12) { f.update(led(on = it % 2 == 0, seed = it), w, h) }
    assertTrue(f.blinking)
  }

  @Test
  fun steadyOrSwitchedOnceIsNotBlinking() {
    val steady = FlickerDetector()
    repeat(20) { steady.update(led(on = true, seed = it), w, h) }
    assertFalse(steady.blinking)
    val once = FlickerDetector()
    repeat(20) { once.update(led(on = it >= 8, seed = it), w, h) }
    assertFalse(once.blinking)
  }

  @Test
  fun turningTheHeadIsNotBlinking() {
    // A textured scene sliding sideways a few pixels per frame, back and forth.
    val f = FlickerDetector()
    for (n in 0 until 24) {
      val shift = listOf(0, 8, 16, 8)[n % 4]
      val px = IntArray(w * h) { i ->
        val x = (i % w) + shift
        val y = i / w
        val v = if ((x / 10 + y / 14) % 2 == 0) 220 else 40
        ColourSpace.argb(v, v, v)
      }
      f.update(px, w, h)
    }
    assertFalse(f.blinking)
  }

  @Test
  fun aFlashingRoomLightIsBlinking() {
    val f = FlickerDetector()
    repeat(16) { f.update(grey(if ((it / 2) % 2 == 0) 200 else 40), w, h) }
    assertTrue(f.blinking)
  }

  @Test
  fun aSlowFadeIsNotBlinking() {
    val f = FlickerDetector()
    for (n in 0 until 20) {
      val v = (40 + 100 * (0.5 + 0.5 * kotlin.math.sin(n * 0.4))).toInt()
      f.update(grey(v), w, h)
    }
    // A smooth sine at 4 fps sits between the levels much of the time.
    assertFalse(f.blinking)
  }

  // MARK: - Grammar

  private fun parse(s: String) = LightGrammar.parse(Phrases.normalize(s))

  @Test
  fun commandsInsideTheTool() {
    for (p in listOf("how bright is it", "How bright is it in here?", "is the light on", "are the lights on", "is it dark in here", "brightness", "are the curtains open")) {
      assertEquals(p, LightCommand.HowBright, parse(p))
    }
    for (p in listOf("where's the light", "where is the window", "which way is the window")) assertEquals(p, LightCommand.WhereBright, parse(p))
    for (p in listOf("is it blinking", "is that flashing", "is the light flickering")) assertEquals(p, LightCommand.IsBlinking, parse(p))
    for (p in listOf("again", "check again", "what about this one", "try again")) assertEquals(p, LightCommand.Again, parse(p))
    for (p in listOf("what colour is this", "What color is it?", "colour mode", "switch to colour mode", "colours")) assertEquals(p, LightCommand.Colour, parse(p))
    for (p in listOf("light mode", "back to the light", "light detector", "tone mode")) assertEquals(p, LightCommand.Light, parse(p))
    for (p in listOf("tone off", "turn the tone off", "mute")) assertEquals(p, LightCommand.ToneOff, parse(p))
    for (p in listOf("tone on", "turn the tone back on", "unmute")) assertEquals(p, LightCommand.ToneOn, parse(p))
  }

  @Test
  fun everydayWordsAreLeftToTheGlobalGrammar() {
    // "quiet", "pause", "carry on" are global; the tool handles them in onGlobal.
    for (p in listOf("quiet", "pause", "stop", "carry on", "close", "help", "read my mail", "scan this", "watch for 42", "say that again")) {
      assertNull(p, parse(p))
    }
    assertEquals(GlobalCommand.Pause, GlobalGrammar.parse("quiet"))
    assertEquals(GlobalCommand.Resume, GlobalGrammar.parse("carry on"))
    // Opening phrases still open the light tool from elsewhere.
    assertEquals(GlobalCommand.Open(ToolRequest(ToolId.LIGHT, mode = ToolRequest.MODE_COLOUR)), GlobalGrammar.parse("what colour is this"))
    assertEquals(GlobalCommand.Open(ToolRequest(ToolId.LIGHT)), GlobalGrammar.parse("light detector"))
    // Room chatter.
    for (p in listOf("turn right at the lights", "it's a lovely colour", "the light was red")) assertNull(p, parse(p))
  }

  @Test
  fun stopsNearOneCycleAfterLog() {
    // Sanity: position() is linear in stops.
    val a = PitchMap.position(0.01)
    val b = PitchMap.position(0.02)
    assertEquals(ln(2.0) / -ln(PitchMap.FLOOR), b - a, 1e-9)
  }
}
