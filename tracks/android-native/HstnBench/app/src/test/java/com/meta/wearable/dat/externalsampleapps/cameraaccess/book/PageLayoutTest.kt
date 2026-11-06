package com.meta.wearable.dat.externalsampleapps.cameraaccess.book

import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.BookFixtures.line
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PageLayoutTest {

  @Test
  fun singlePageDropsHeaderAndPageNumberAndBuildsParagraphs() {
    val result = PageLayout.layout(BookFixtures.houndPage)

    assertEquals(1, result.pages.size)
    val page = result.pages[0]
    assertEquals(PageSide.SINGLE, page.side)
    assertEquals("THE HOUND OF THE BASKERVILLES", page.header)
    assertEquals("3", page.pageNumber)
    assertEquals(BookFixtures.houndParagraphs, result.readingParagraphs(includeFurniture = false))
  }

  @Test
  fun hyphenatedLineEndIsRejoinedButRealHyphensStay() {
    val text = PageLayout.layout(BookFixtures.houndPage).bodyText()
    assertTrue(text.contains("the night before."))
    assertTrue(text.contains("my occupation."))
    assertTrue(text.contains("hearth-rug"))
    assertTrue(text.contains("bulbous-headed"))
    assertFalse(text.contains("be- fore"))
  }

  @Test
  fun furnitureIsAnnouncedWhenVerbose() {
    val paragraphs = PageLayout.layout(BookFixtures.houndPage).readingParagraphs(includeFurniture = true)
    assertEquals("Page 3.", paragraphs[0])
    assertEquals("THE HOUND OF THE BASKERVILLES.", paragraphs[1])
    assertEquals(BookFixtures.houndParagraphs, paragraphs.drop(2))
  }

  @Test
  fun spreadIsSplitAtGutterAndReadLeftThenRight() {
    val result = PageLayout.layout(BookFixtures.spreadPage)

    assertEquals(listOf(PageSide.LEFT, PageSide.RIGHT), result.pages.map { it.side })
    assertEquals("THE TIME MACHINE", result.pages[0].header)
    assertEquals("42", result.pages[0].pageNumber)
    assertEquals("A STRANGE ARRIVAL", result.pages[1].header)
    assertEquals("43", result.pages[1].pageNumber)
    assertEquals(BookFixtures.spreadParagraphs, result.readingParagraphs(includeFurniture = false))
  }

  @Test
  fun wordBrokenAcrossGutterIsRejoinedEvenWithFurniture() {
    val paragraphs =
        PageLayout.layout(BookFixtures.spreadPage).readingParagraphs(includeFurniture = true)
    val joined = paragraphs.joinToString(" | ")
    assertTrue(joined, joined.contains("It is extraordinarily"))
    assertTrue(joined, paragraphs.indexOf("Page 43.") > paragraphs.indexOfFirst { it.contains("extraordinarily") })
    assertFalse(joined, joined.contains("extraor-"))
  }

  @Test
  fun gutterNotFoundOnSinglePage() {
    assertNull(PageLayout.findGutter(BookFixtures.houndLines))
    assertNotNull(PageLayout.findGutter(BookFixtures.spreadLines))
  }

  @Test
  fun shortLinesOfVerseAreNotMistakenForASpread() {
    // Poetry: every line starts at the left margin and stops short, leaving the right half empty.
    val verse =
        listOf(
            "Tyger Tyger, burning bright,",
            "In the forests of the night;",
            "What immortal hand or eye,",
            "Could frame thy fearful symmetry?",
            "In what distant deeps or skies.",
            "Burnt the fire of thine eyes?",
            "On what wings dare he aspire?",
            "What the hand, dare seize the fire?",
        )
            .mapIndexed { i, t -> line(t, 90f, 130f + i * 34f, 90f + t.length * 11f) }
    assertNull(PageLayout.findGutter(verse))
  }

  @Test
  fun romanNumeralPageNumberAtFootIsDropped() {
    val lines =
        BookFixtures.houndLines.dropLast(1) + line("xiv", 465f, 1360f, 500f, height = 22f)
    val page = PageLayout.layout(OcrPage.ofLines(960, 1440, lines)).pages[0]
    assertEquals("xiv", page.pageNumber)
    assertFalse(page.paragraphs.last().endsWith("xiv"))
  }

  @Test
  fun chapterHeadingIsKeptAsContent() {
    val lines =
        listOf(
            line("CHAPTER ONE", 380f, 200f, 580f, height = 24f),
            line("It was a bright cold day in April, and the clocks were striking", 130f, 300f, 870f),
            line("thirteen. Winston Smith slipped quickly through the glass doors.", 90f, 334f, 870f),
            line("The hallway smelt of boiled cabbage and old rag mats.", 90f, 368f, 700f),
        )
    val result = PageLayout.layout(OcrPage.ofLines(960, 1440, lines))
    assertNull(result.pages[0].header)
    assertEquals("CHAPTER ONE", result.readingParagraphs(false).first())
  }

  @Test
  fun rowSegmentsAreMergedLeftToRight() {
    val ordered =
        PageLayout.readingOrder(
            listOf(
                line("world", 300f, 101f, 400f),
                line("hello", 100f, 100f, 200f),
                line("next line", 100f, 140f, 300f),
            ),
        )
    assertEquals(listOf("hello world", "next line"), ordered.map { it.text })
  }

  @Test
  fun joinLineHandlesHyphensAndDashes() {
    fun join(a: String, b: String) = StringBuilder(a).also { PageLayout.joinLine(it, b) }.toString()
    assertEquals("example", join("exam-", "ple"))
    assertEquals("anti-American", join("anti-", "American"))
    assertEquals("example", join("exam­", "ple"))
    assertEquals("wait—then", join("wait—", "then"))
    assertEquals("one two", join("one", "two"))
    assertEquals("pages 12-14", join("pages 12-", "14"))
  }

  @Test
  fun misreadLineEndFragmentIsRepairedWhenRejoined() {
    fun join(a: String, b: String) = StringBuilder(a).also { PageLayout.joinLine(it, b) }.toString()
    // ML Kit on a Galaxy A26 read the fragment "oc-" as "0C-" (BookReaderTest).
    assertEquals("not infrequent occasions", join("not infrequent 0C-", "casions"))
    assertEquals("It was. Occasions", join("It was. 0C-", "casions"))
    assertEquals("strong words", join("strong w0r-", "ds"))
    assertEquals("exxample", join("exX-", "ample")) // case fixed; the doubled glyph stays
    // Not rejoined (next line starts with a capital): nothing is repaired.
    assertEquals("0C-Casions", join("0C-", "Casions"))
    // Real capitals and digits are left alone.
    assertEquals("McCarthy", join("McCar-", "thy"))
    assertEquals("B2Bthing", join("B2B-", "thing"))
    assertEquals("pages 10-14", join("pages 10-", "14"))
  }

  @Test
  fun emptyPageGivesEmptyResult() {
    assertTrue(PageLayout.layout(OcrPage(960, 1440, emptyList())).isEmpty)
  }
}
