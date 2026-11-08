// WatchMatchingTest - target parsing and text matching for Watch for text
//
// Pins the matching rules: numbers exact (42 is not 421, 142, 4.2 or 42A, but is "No. 42" and the
// 42 between words on a bus front), words loose (case, punctuation, a missing letter, digit-for-letter
// OCR slips), multi-word targets side by side on one line, codes, spoken number words, the position
// of a match inside a wide line, and "I see 24, not 42" near misses.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.watch

import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.Box
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.OcrLine
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.OcrPage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WatchMatchingTest {

  private fun t(raw: String) = WatchTarget.parse(raw)!!

  private fun found(target: String, line: String) = TextMatcher.findInLine(t(target), line) != null

  // MARK: target parsing

  @Test
  fun targetsAreParsedIntoNumbersCodesAndWords() {
    assertEquals(listOf(TargetToken("42", TokenKind.NUMBER)), t("42").tokens)
    assertEquals("42", t("forty two").display)
    assertEquals("42", t("four two").display)
    assertEquals("101", t("one oh one").display)
    assertEquals("101", t("one hundred and one").display)
    assertEquals("73", t("the 73 bus").display)
    assertEquals("73", t("bus number 73").display)
    assertEquals("42", t("number 42").display)
    assertEquals("platform 3", t("platform three").display)
    assertEquals("gate 12", t("gate twelve").display)
    assertEquals("room 12B", t("room 12 b").display)
    assertEquals(TokenKind.CODE, t("12b").tokens.single().kind)
    assertEquals("one way", t("one way").display)
    assertEquals("boots", t("Boots").display)
    assertEquals("exit", t("the exit").display)
    assertEquals("sainsburys", t("Sainsbury's").display)
    assertTrue(t("42").isSingleNumber)
    assertFalse(t("platform 3").isSingleNumber)
    assertNull(WatchTarget.parse("the"))
    assertNull(WatchTarget.parse("  "))
  }

  @Test
  fun numberWords() {
    assertEquals("7", NumberWords.parse(listOf("seven")))
    assertEquals("15", NumberWords.parse(listOf("fifteen")))
    assertEquals("90", NumberWords.parse(listOf("ninety")))
    assertEquals("250", NumberWords.parse(listOf("two", "hundred", "fifty")))
    assertNull(NumberWords.parse(listOf("forty", "way")))
    assertNull(NumberWords.parse(listOf("one", "way")))
  }

  // MARK: numbers are exact

  @Test
  fun fortyTwoMatchesOnlyFortyTwo() {
    assertTrue(found("42", "42"))
    assertTrue(found("42", "42 Victoria Station"))
    assertTrue(found("42", "via Town Centre 42 Victoria"))
    assertTrue(found("42", "No. 42"))
    assertTrue(found("42", "No.42"))
    assertTrue(found("42", "Bus 42,"))
    assertTrue(found("42", "(42)"))
    assertTrue(found("42", "No42"))
    assertFalse(found("42", "4O")) // O read for a zero: that's 40
    assertTrue(found("40", "4O"))
    assertTrue(found("11", "1l"))

    assertFalse(found("42", "421"))
    assertFalse(found("42", "142"))
    assertFalse(found("42", "4.2"))
    assertFalse(found("42", "42.5"))
    assertFalse(found("42", "4,2"))
    assertFalse(found("42", "42A"))
    assertFalse(found("42", "Route 421 Airport"))
    assertFalse(found("42", "4 2"))
    assertFalse(found("42", "24"))
    assertFalse(found("42", "10:42"))
  }

  @Test
  fun leadingZerosDontMatter() {
    assertTrue(found("4", "Gate 04"))
    assertTrue(found("gate 4", "GATE 04"))
  }

  @Test
  fun codesAreExactIgnoringCaseAndSlips() {
    assertTrue(found("12b", "Room 12B"))
    assertTrue(found("12b", "ROOM 12 B"))
    assertTrue(found("12b", "I2B"))
    assertFalse(found("12b", "12C"))
    assertFalse(found("12b", "112B"))
    assertFalse(found("12b", "12"))
  }

  // MARK: words are loose

  @Test
  fun wordsMatchLoosely() {
    assertTrue(found("exit", "EXIT"))
    assertTrue(found("exit", "Exit."))
    assertTrue(found("exit", "<- exit ->"))
    assertTrue(found("boots", "Boots"))
    assertTrue(found("boots", "BOOTS PHARMACY"))
    assertTrue(found("boots", "Bots")) // a missing letter
    assertTrue(found("boots", "B00TS")) // zeros read for O
    assertTrue(found("boots", "BO OTS")) // split by OCR
    assertTrue(found("sainsburys", "SAINSBURY'S"))
    assertTrue(found("sainsburys", "SAINSBURYS"))
    assertTrue(found("pharmacy", "PHARMCY")) // 8 letters: 2 edits allowed
    assertTrue(found("toilets", "Toilets"))
    assertTrue(found("toilets", "Tollets"))

    assertFalse(found("boots", "Boston"))
    assertFalse(found("boots", "Bootstrap"))
    assertFalse(found("exit", "exiting")) // 3 letters more
    assertFalse(found("bus", "bun")) // 3 letters: exact only
    assertFalse(found("boots", ""))
  }

  // MARK: several words

  @Test
  fun multiWordTargetsMatchSideBySide() {
    assertTrue(found("platform 3", "Platform 3"))
    assertTrue(found("platform 3", "To Platform 3 and 4"))
    assertTrue(found("platform 3", "PLATFORM3"))
    assertTrue(found("platform 3", "PLATF0RM 3"))
    assertTrue(found("right exit", "Right exit"))
    assertTrue(found("way out", "WAY OUT ->"))

    assertFalse(found("platform 3", "Platform 13"))
    assertFalse(found("platform 3", "Platform 31"))
    assertFalse(found("platform 3", "Platform 4"))
    assertFalse(found("platform 3", "3 Platform"))
    assertFalse(found("platform 3", "Platform"))
    assertFalse(found("platform 3", "PLATFORM31"))
    assertFalse(found("way out", "way in out"))
  }

  // MARK: finding it in a frame

  private fun page(vararg lines: OcrLine) = OcrPage.ofLines(1000, 2000, lines.toList())

  private fun line(text: String, left: Float, top: Float, right: Float, bottom: Float) =
      OcrLine(text, Box(left, top, right, bottom))

  @Test
  fun positionIsTheMatchedPartOfTheLine() {
    // "42" at the start of a wide line: placed left of the line's centre.
    val m = TextMatcher.find(t("42"), page(line("42 VICTORIA", 100f, 100f, 900f, 200f)))
    val spot = m.hit!!
    assertTrue("x=${spot.x}", spot.x < 0.25f)
    assertEquals("42", spot.text)
    assertEquals(0.05f, spot.heightFraction, 0.001f)

    val right = TextMatcher.find(t("42"), page(line("42", 800f, 500f, 900f, 600f))).hit!!
    assertEquals(0.85f, right.x, 0.01f)
    assertEquals(Side.RIGHT, Position.side(right.x))
  }

  @Test
  fun theTallestSightingWins() {
    val m =
        TextMatcher.find(
            t("exit"),
            page(line("exit", 100f, 100f, 200f, 130f), line("EXIT", 600f, 400f, 900f, 600f)),
        )
    assertEquals(0.1f, m.hit!!.heightFraction, 0.001f)
  }

  @Test
  fun nearMissesAreSwapsAndOneDigitOffForLongNumbers() {
    assertTrue(TextMatcher.isNearMiss("42", "24"))
    assertFalse(TextMatcher.isNearMiss("42", "43")) // 2 digits: swaps only
    assertFalse(TextMatcher.isNearMiss("42", "421"))
    assertFalse(TextMatcher.isNearMiss("42", "42"))
    assertTrue(TextMatcher.isNearMiss("123", "132"))
    assertTrue(TextMatcher.isNearMiss("123", "124"))
    assertFalse(TextMatcher.isNearMiss("123", "456"))

    val near = TextMatcher.find(t("42"), page(line("24 Town Centre", 0f, 0f, 500f, 100f)))
    assertNull(near.hit)
    assertEquals("24", near.nearMiss)
    // A hit beats a near miss on another line.
    val both = TextMatcher.find(t("42"), page(line("24", 0f, 0f, 100f, 100f), line("42", 0f, 300f, 100f, 400f)))
    assertNotNull(both.hit)
    assertNull(both.nearMiss)
    // Words have no near misses.
    assertNull(TextMatcher.find(t("toilets"), page(line("tablets", 0f, 0f, 100f, 100f))).nearMiss)
    assertEquals(FrameMatch.NONE, TextMatcher.find(t("42"), page(line("421", 0f, 0f, 100f, 100f))))
  }

  @Test
  fun tokensSeparateDecimalsFromNumbers() {
    val toks = TextMatcher.tokens("No. 42 at 4.2 km, 10:30")
    assertEquals(listOf("no", "42", "at", "4.2", "km", "10:30"), toks.map { it.text })
    assertEquals(listOf(OcrKind.WORD, OcrKind.NUMBER, OcrKind.WORD, OcrKind.DECIMAL, OcrKind.WORD, OcrKind.DECIMAL), toks.map { it.kind })
  }
}
