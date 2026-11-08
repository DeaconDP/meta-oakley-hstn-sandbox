// ColourReaderTest - naming colours from synthetic frames, and hedging when the evidence is weak
//
// Known sRGB patches in neutral light get their everyday names; the same colours under warm light
// are hedged and never confidently called something else (red never "orange"); dark frames abstain;
// stripes give two colours; white balance measures a cast; OKLab matches published values.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.light

import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.light.LightFixtures.Rgb
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.light.LightFixtures.frame
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.light.LightFixtures.read
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ColourReaderTest {

  private fun say(r: ColourResult) = ColourSpeech.describe(r)

  @Test
  fun oklabMatchesReferenceValues() {
    val white = ColourSpace.oklab(255, 255, 255)
    assertEquals(1.0, white.l, 0.001)
    assertEquals(0.0, white.chroma, 0.001)
    val red = ColourSpace.oklab(255, 0, 0)
    // Ottosson's reference: sRGB red = (0.628, 0.225, 0.126).
    assertEquals(0.628, red.l, 0.002)
    assertEquals(0.225, red.a, 0.002)
    assertEquals(0.126, red.b, 0.002)
    val blue = ColourSpace.oklab(0, 0, 255)
    assertEquals(0.452, blue.l, 0.002)
    assertEquals(-0.032, blue.a, 0.002)
    assertEquals(-0.312, blue.b, 0.002)
    for (v in listOf(0, 1, 10, 50, 128, 200, 254, 255)) assertEquals(v, ColourSpace.toSrgb(ColourSpace.toLinear(v)))
  }

  @Test
  fun knownPatchesInNeutralLightGetTheirNamesConfidently() {
    val expected =
        mapOf(
            Rgb(0, 0, 128) to "Navy blue.",
            Rgb(20, 30, 95) to "Navy blue.",
            Rgb(255, 0, 0) to "Red.",
            Rgb(205, 30, 35) to "Red.",
            Rgb(100, 20, 45) to "Burgundy.",
            Rgb(20, 80, 35) to "Dark green.",
            Rgb(0, 128, 0) to "Green.",
            Rgb(215, 195, 160) to "Beige.",
            Rgb(128, 128, 128) to "Grey.",
            Rgb(15, 15, 15) to "Black.",
            Rgb(245, 245, 245) to "White.",
            Rgb(255, 192, 203) to "Light pink.",
            Rgb(240, 140, 175) to "Pink.",
            Rgb(245, 130, 25) to "Orange.",
            Rgb(120, 70, 35) to "Brown.",
            Rgb(128, 0, 128) to "Purple.",
            Rgb(65, 105, 225) to "Blue.",
            Rgb(135, 206, 235) to "Light blue.",
            Rgb(0, 128, 128) to "Teal.",
            Rgb(255, 255, 0) to "Yellow.",
            Rgb(128, 128, 0) to "Olive green.",
            Rgb(255, 127, 80) to "Coral.",
            Rgb(64, 224, 208) to "Turquoise.",
        )
    for ((c, name) in expected) {
      val r = read(frame(c))
      assertEquals("$c", name, say(r))
      assertEquals("$c", Confidence.CONFIDENT, r.confidence)
    }
  }

  @Test
  fun lightAndDarkModifiers() {
    // Plain names take a modifier when clearly lighter or darker than the palette's colour.
    val blue = ColourPalette.COLOURS.first { it.name == "blue" }.lab
    val darker = ColourPalette.nearest(blue.copy(l = blue.l - 0.13)).name
    assertTrue(darker, darker == "dark blue" || darker == "navy blue")
    assertEquals("light blue", ColourPalette.nearest(ColourSpace.oklab(150, 200, 240)).name)
    // Just past the threshold, plain names get the modifier (unless a named shade is nearer).
    val modified = ColourPalette.COLOURS.filter { it.modifiable }.flatMap { c ->
      listOf(0.125, -0.125).map { dl -> c.name to ColourPalette.nearest(c.lab.copy(l = c.lab.l + dl)).name }
    }
    assertTrue("$modified", modified.count { (base, name) -> name == "light $base" || name == "dark $base" } >= 3)
    assertTrue("$modified", modified.none { (_, name) -> name.startsWith("light light") || name.startsWith("dark dark") })
    // Names that already carry their shade don't get another.
    assertEquals("navy blue", ColourPalette.nearest(ColourSpace.oklab(20, 30, 95)).name)
  }

  @Test
  fun betweenTwoFamiliesIsHedgedWithBothNames() {
    val r = read(frame(Rgb(255, 165, 0)))
    assertEquals(Confidence.PROBABLE, r.confidence)
    assertTrue(say(r), say(r).startsWith("Probably orange, or maybe"))
  }

  @Test
  fun redUnderWarmLightIsStillRedOrHedgedNeverConfidentlyOrange() {
    for (red in listOf(Rgb(205, 30, 35), Rgb(255, 0, 0), Rgb(180, 20, 30), Rgb(150, 25, 30))) {
      for (light in listOf(LightFixtures.WARM, LightFixtures.VERY_WARM)) {
        val r = read(frame(red, light = light))
        val text = say(r)
        assertNotEquals("$red $light: $text", Confidence.CONFIDENT, r.confidence)
        assertEquals("$red $light: $text", ColourFamily.RED, r.main!!.match.colour.family)
        assertTrue("$red $light: $text", "orange" !in text && "coral" !in text)
        assertTrue(text, "yellowish" in text)
      }
    }
  }

  @Test
  fun noColourIsConfidentUnderAStrongCast() {
    val all = ColourPalette.COLOURS.map { Rgb(it.r, it.g, it.b) }
    for (c in all) for (light in listOf(LightFixtures.WARM, LightFixtures.VERY_WARM)) {
      val r = read(frame(c, light = light))
      assertNotEquals("$c $light: ${say(r)}", Confidence.CONFIDENT, r.confidence)
    }
    // A very strong cast on white gives "hard to tell", not a confident "cream".
    val white = read(frame(Rgb(245, 245, 245), light = LightFixtures.VERY_WARM))
    assertEquals(Confidence.UNSURE, white.confidence)
    assertTrue(say(white), say(white).startsWith("Hard to tell in this light."))
  }

  @Test
  fun whiteBalanceMeasuresTheCastAndCorrectsIt() {
    val neutral = ColourReader.whiteBalance(frame(Rgb(128, 128, 128)).toList())
    assertEquals(1.0, neutral.cast, 0.05)
    val warm = ColourReader.whiteBalance(frame(Rgb(128, 128, 128), light = LightFixtures.WARM).toList())
    assertTrue("cast ${warm.cast}", warm.cast > 1.8)
    assertTrue("warmth ${warm.warmth}", warm.warmth > 1.8)
    assertTrue("blue boosted", warm.gainB > warm.gainR)
    // Moderately warm light: the correction brings red back to red (hedged for the cast).
    val r = read(frame(Rgb(205, 30, 35), light = LightFixtures.WARM))
    assertEquals("red", r.main!!.match.name)
    assertEquals(Confidence.PROBABLE, r.confidence)
    assertEquals("Probably red. The light looks yellowish, which shifts colours.", say(r))
  }

  @Test
  fun darkFrameIsTooDarkToTell() {
    val dark = frame(Rgb(30, 10, 10), surround = Rgb(10, 10, 10), noise = 2)
    val r = read(dark)
    assertEquals(Confidence.ABSTAIN, r.confidence)
    assertNull(r.main)
    assertTrue(say(r), say(r).startsWith("Too dark to tell."))
    // Same scene underexposed from a normal one.
    val under = read(frame(Rgb(205, 30, 35), exposure = 0.01))
    assertEquals(Confidence.ABSTAIN, under.confidence)
  }

  @Test
  fun dimLightIsHedged() {
    val r = read(frame(Rgb(205, 30, 35), exposure = 0.12))
    assertTrue("${r.confidence} ${say(r)}", r.confidence == Confidence.PROBABLE || r.confidence == Confidence.UNSURE)
    assertTrue(say(r), "dim" in say(r))
    val veryDim = read(frame(Rgb(205, 30, 35), exposure = 0.05))
    assertTrue("${veryDim.confidence} ${say(veryDim)}", veryDim.confidence >= Confidence.UNSURE)
  }

  @Test
  fun blackInGoodLightIsBlackNotTooDark() {
    val r = read(frame(Rgb(15, 15, 15), surround = Rgb(170, 170, 170)))
    assertEquals("Black.", say(r))
  }

  @Test
  fun glareAbstains() {
    val r = read(frame(Rgb(255, 255, 255), surround = Rgb(150, 150, 150), noise = 0))
    assertEquals(Confidence.ABSTAIN, r.confidence)
    assertTrue(say(r), say(r).startsWith("Too much glare"))
  }

  @Test
  fun mutedColourIsHedged() {
    val r = read(frame(Rgb(245, 245, 220)))
    assertEquals(Confidence.PROBABLE, r.confidence)
    assertTrue(say(r), say(r).startsWith("Probably cream"))
  }

  @Test
  fun stripesGiveTwoColours() {
    // 70% white, 30% blue.
    val mostly = read(frame(Rgb(245, 245, 245), stripe = Rgb(40, 90, 205), stripeShare = 0.3))
    assertEquals("Mostly white, with blue.", say(mostly))
    // Even stripes.
    val even = read(frame(Rgb(245, 245, 245), stripe = Rgb(20, 30, 95), stripeShare = 0.5))
    val text = say(even)
    assertTrue(text, text == "White and navy blue." || text == "Navy blue and white.")
    // A thin pinstripe (10%) doesn't count as a second colour.
    val pin = read(frame(Rgb(20, 30, 95), stripe = Rgb(245, 245, 245), stripeShare = 0.1))
    assertEquals("Navy blue.", say(pin))
  }

  @Test
  fun backgroundAroundASmallPatchDoesNotChangeTheAnswer() {
    // The object only just covers the patch; the room is bright green.
    val r = read(frame(Rgb(205, 30, 35), surround = Rgb(60, 160, 60), objectFraction = 0.25))
    assertEquals("red", r.main!!.match.name)
    assertNull(r.second)
  }

  @Test
  fun swatchIsTheBalancedColour() {
    val r = read(frame(Rgb(20, 30, 95), noise = 0))
    val s = r.swatch
    assertEquals(20.0, ColourSpace.red(s).toDouble(), 3.0)
    assertEquals(30.0, ColourSpace.green(s).toDouble(), 3.0)
    assertEquals(95.0, ColourSpace.blue(s).toDouble(), 3.0)
  }
}
