package com.meta.wearable.dat.externalsampleapps.cameraaccess.book

import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.BookFixtures.line
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FramingCheckTest {

  @Test
  fun wellFramedPageIsOk() {
    val result = FramingCheck.check(BookFixtures.houndPage)
    assertTrue(result.issues.toString(), result.isOk)
    assertEquals(null, result.hint)
    assertTrue(FramingCheck.check(BookFixtures.spreadPage).isOk)
  }

  @Test
  fun rightEdgeCutOffSaysTurnRight() {
    val result = FramingCheck.check(BookFixtures.cutOffRight(BookFixtures.houndPage))
    assertEquals(listOf(FramingIssue.CUT_RIGHT), result.issues)
    assertEquals("Page cut off on the right. Turn your head right.", result.hint)
    assertFalse(result.isUnreadable)
  }

  @Test
  fun leftAndBottomCombine() {
    val lines =
        (0 until 10).map { i ->
          line("body text running off the left side of the frame $i", 0f, 1000f + i * 45f, 700f)
        }
    val result = FramingCheck.check(OcrPage.ofLines(960, 1440, lines))
    assertEquals(listOf(FramingIssue.CUT_LEFT, FramingIssue.CUT_BOTTOM), result.issues)
    assertEquals(
        "Page cut off on the left and at the bottom. Turn your head left and tilt your head down.",
        result.hint,
    )
  }

  @Test
  fun bothSidesCutMeansTooClose() {
    val lines = (0 until 8).map { i -> line("text wider than the whole frame $i", 0f, 300f + i * 40f, 960f) }
    val result = FramingCheck.check(OcrPage.ofLines(960, 1440, lines))
    assertEquals(listOf(FramingIssue.TOO_CLOSE), result.issues)
    assertTrue(result.hint!!.contains("further away"))
  }

  @Test
  fun noTextAndLowConfidenceAreUnreadable() {
    val empty = FramingCheck.check(OcrPage(960, 1440, emptyList()))
    assertEquals(listOf(FramingIssue.NO_TEXT), empty.issues)
    assertTrue(empty.isUnreadable)
    assertEquals("Can't read this. Hold the book steady, a little closer.", empty.hint)

    val crumbs = FramingCheck.check(OcrPage.ofLines(960, 1440, listOf(line("a 4", 400f, 600f, 440f))))
    assertEquals(listOf(FramingIssue.NO_TEXT), crumbs.issues)

    val blurry =
        OcrPage.ofLines(
            960,
            1440,
            BookFixtures.houndLines.map { it.copy(confidence = 0.3f) },
        )
    assertEquals(listOf(FramingIssue.LOW_CONFIDENCE), FramingCheck.check(blurry).issues)
  }

  @Test
  fun tinyTextAsksToComeCloser() {
    val lines = (0 until 20).map { i -> line("tiny far away print on a distant page", 300f, 500f + i * 12f, 600f, height = 8f) }
    val result = FramingCheck.check(OcrPage.ofLines(960, 1440, lines))
    assertEquals(listOf(FramingIssue.TOO_SMALL), result.issues)
    assertTrue(result.hint!!.contains("closer"))
  }

  @Test
  fun missingConfidenceIsNotLowConfidence() {
    val noConf = OcrPage.ofLines(960, 1440, BookFixtures.houndLines.map { it.copy(confidence = null) })
    assertTrue(FramingCheck.check(noConf).isOk)
  }
}

class PageDedupTest {

  private val hound = PageLayout.layout(BookFixtures.houndPage).bodyText()
  private val houndAgain = PageLayout.layout(BookFixtures.houndPageReOcr).bodyText()
  private val houndNext = PageLayout.layout(BookFixtures.houndNextPage).bodyText()

  @Test
  fun sameOcrIsSamePage() {
    assertEquals(1f, PageDedup.similarity(hound, hound), 0.0001f)
  }

  @Test
  fun reOcrWithErrorsAndAMissingLineIsSamePage() {
    assertTrue(PageDedup.similarity(hound, houndAgain).toString(), PageDedup.isSamePage(hound, houndAgain))
  }

  @Test
  fun nextPageIsDifferent() {
    val s = PageDedup.similarity(hound, houndNext)
    assertTrue("similarity=$s", s < 0.1f)
    assertFalse(PageDedup.isSamePage(hound, houndNext))
  }

  @Test
  fun halfOfTheSamePageIsSamePage() {
    val half = hound.substring(0, hound.length / 2)
    assertTrue(PageDedup.isSamePage(hound, half))
  }

  @Test
  fun noPreviousPageIsNeverSame() {
    assertFalse(PageDedup.isSamePage(null, hound))
  }

  @Test
  fun shortTextsUseCharacterSimilarity() {
    assertTrue(PageDedup.isSamePage("The End", "The End."))
    assertFalse(PageDedup.isSamePage("The End", "Chapter Two"))
  }
}

class TextDistanceTest {

  @Test
  fun cerAndWer() {
    assertEquals(0f, TextDistance.cer("hello world", "hello  world\n"), 0f)
    assertEquals(1f / 11f, TextDistance.cer("hello world", "hallo world"), 1e-6f)
    assertEquals(0.5f, TextDistance.wer("hello world", "hallo world"), 1e-6f)
    assertEquals(1f, TextDistance.wer("", "x"), 0f)
    assertEquals(0f, TextDistance.wer("", ""), 0f)
    assertEquals(3, TextDistance.levenshtein("kitten".toList(), "sitting".toList()))
  }
}
