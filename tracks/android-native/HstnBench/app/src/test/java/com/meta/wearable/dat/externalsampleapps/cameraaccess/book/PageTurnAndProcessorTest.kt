package com.meta.wearable.dat.externalsampleapps.cameraaccess.book

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PageTurnDetectorTest {

  private fun PageTurnDetector.feed(vararg changes: Float, text: Boolean? = null): List<TurnEvent> =
      changes.toList().mapNotNull { onFrame(FrameSignal(it, text)) }

  @Test
  fun stillReadingProducesNoEvents() {
    val d = PageTurnDetector()
    assertTrue(d.feed(0.01f, 0.02f, 0.0f, 0.05f, 0.03f).isEmpty())
    assertEquals(TurnState.READING, d.state)
  }

  @Test
  fun singleFrameSpikeIsIgnored() {
    val d = PageTurnDetector()
    assertTrue(d.feed(0.02f, 0.9f, 0.02f, 0.02f, 0.9f, 0.01f).isEmpty())
    assertEquals(TurnState.READING, d.state)
  }

  @Test
  fun fullTurnThenSettleCaptures() {
    val d = PageTurnDetector()
    val events = d.feed(0.02f, 0.6f, 0.8f, 0.7f, 0.4f, 0.05f, 0.03f, 0.02f, 0.04f, 0.01f)
    assertEquals(
        listOf(TurnEvent.TurnStarted, TurnEvent.Settling, TurnEvent.Capture(manual = false)),
        events,
    )
    assertEquals(TurnState.CAPTURE, d.state)
    // Frames during the capture are ignored.
    assertTrue(d.feed(0.9f, 0.9f, 0.9f).isEmpty())
    d.captureDone()
    assertEquals(TurnState.READING, d.state)
  }

  @Test
  fun jitterWhileSettlingRestartsTheCount() {
    val d = PageTurnDetector(PageTurnDetector.Config(settleFrames = 3))
    d.feed(0.5f, 0.5f) // turning
    assertEquals(listOf(TurnEvent.Settling), d.feed(0.01f, 0.01f))
    assertTrue(d.feed(0.2f).isEmpty()) // jitter: not still, not a turn
    assertEquals(TurnState.SETTLING, d.state)
    assertTrue(d.feed(0.01f, 0.01f).isEmpty())
    assertEquals(listOf(TurnEvent.Capture(false)), d.feed(0.01f))
  }

  @Test
  fun bigMotionWhileSettlingGoesBackToTurning() {
    val d = PageTurnDetector()
    d.feed(0.5f, 0.5f, 0.01f)
    assertEquals(TurnState.SETTLING, d.state)
    d.feed(0.8f)
    assertEquals(TurnState.TURNING, d.state)
  }

  @Test
  fun noTextInViewHoldsTheCapture() {
    val d = PageTurnDetector(PageTurnDetector.Config(settleFrames = 3))
    d.feed(0.5f, 0.5f)
    assertTrue(d.feed(0.01f, 0.01f, 0.01f, 0.01f, text = false).filterIsInstance<TurnEvent.Capture>().isEmpty())
    assertEquals(listOf(TurnEvent.Capture(false)), d.feed(0.01f, 0.01f, 0.01f, text = true))
  }

  @Test
  fun manualNextPageCapturesImmediately() {
    val d = PageTurnDetector()
    assertEquals(TurnEvent.Capture(manual = true), d.nextPage())
    assertEquals(TurnState.CAPTURE, d.state)
  }

  @Test
  fun frameSizeMotionScoresBigFramesHigh() {
    val m = FrameSizeMotion()
    assertNull(m.onFrame(4000, isCodecConfig = true))
    val still = (0 until 20).mapNotNull { m.onFrame(500 + (it % 3) * 20) }
    assertTrue(still.all { it < 0.1f })
    val moving = (0 until 4).mapNotNull { m.onFrame(4000) }
    assertTrue(moving.toString(), moving.all { it >= 0.35f })
    // Back to still: the baseline didn't absorb the turn.
    val after = (0 until 3).mapNotNull { m.onFrame(520) }
    assertTrue(after.all { it < 0.1f })
  }

  @Test
  fun motionScoresDriveTheDetector() {
    val m = FrameSizeMotion()
    val d = PageTurnDetector()
    val sizes = List(10) { 500 } + List(5) { 5000 } + List(8) { 480 }
    val events = sizes.mapNotNull { m.onFrame(it) }.mapNotNull { d.onFrame(FrameSignal(it)) }
    assertEquals(TurnEvent.Capture(false), events.last())
  }
}

class PageProcessorTest {

  @Test
  fun readsThenRecognisesTheSamePage() {
    val p = PageProcessor()
    val first = p.process(BookFixtures.houndPage, includeFurniture = false)
    assertTrue(first is PageOutcome.Read)
    first as PageOutcome.Read
    assertEquals(BookFixtures.houndParagraphs, first.paragraphs)
    assertEquals("Mr. Sherlock Holmes, who was usually very late in the mornings, save upon those not infrequent occasions when he was up all night, was seated at the breakfast table.", first.chunks[0].sentenceText)

    assertTrue(p.process(BookFixtures.houndPageReOcr, includeFurniture = false) is PageOutcome.SamePage)
    assertTrue(p.process(BookFixtures.houndNextPage, includeFurniture = false) is PageOutcome.Read)
  }

  @Test
  fun cutOffPageGivesAHintUnlessForced() {
    val p = PageProcessor()
    val cut = BookFixtures.cutOffRight(BookFixtures.houndPage)
    val hint = p.process(cut, includeFurniture = false)
    assertTrue(hint is PageOutcome.Hint)
    assertEquals("Page cut off on the right. Turn your head right.", (hint as PageOutcome.Hint).framing.hint)
    assertTrue(p.process(cut, includeFurniture = false, forceRead = true) is PageOutcome.Read)
  }

  @Test
  fun samePageWinsOverCutOffHint() {
    val p = PageProcessor()
    p.process(BookFixtures.houndPage, includeFurniture = false)
    assertTrue(p.process(BookFixtures.cutOffRight(BookFixtures.houndPage), false) is PageOutcome.SamePage)
  }

  @Test
  fun unreadableIsNeverForced() {
    val p = PageProcessor()
    val out = p.process(OcrPage(960, 1440, emptyList()), includeFurniture = false, forceRead = true)
    assertTrue(out is PageOutcome.Hint)
  }

  @Test
  fun wordBrokenAcrossCapturesIsCarried() {
    val p = PageProcessor()
    val first = p.process(BookFixtures.houndNextPage, includeFurniture = false) as PageOutcome.Read
    // houndNextPage ends cleanly; make a page that ends mid-word.
    val endsBroken =
        OcrPage.ofLines(
            960,
            1440,
            BookFixtures.houndLines.filterNot { it.text == "pation." },
        )
    val second = p.process(endsBroken, includeFurniture = true) as PageOutcome.Read
    assertEquals("occu", p.carry)
    assertFalse(second.chunks.last().text.contains("occu"))
    assertTrue(second.chunks.last().text.endsWith("no sign of my"))

    val third =
        OcrPage.ofLines(
            960,
            1440,
            listOf(
                BookFixtures.line("pation. Holmes turned to the fire and lit his pipe without", 90f, 130f, 870f),
                BookFixtures.line("another word, and I knew better than to press him on it.", 90f, 164f, 700f),
                BookFixtures.line("5", 470f, 1360f, 490f, height = 22f),
            ),
        )
    val out = p.process(third, includeFurniture = true) as PageOutcome.Read
    assertEquals("Page 5.", out.paragraphs[0])
    assertTrue(out.paragraphs[1], out.paragraphs[1].startsWith("occupation. Holmes turned"))
    assertNull(p.carry)
    assertTrue(first.chunks.isNotEmpty())
  }

  @Test
  fun flushCarryReturnsFragmentOnce() {
    val p = PageProcessor()
    p.process(OcrPage.ofLines(960, 1440, BookFixtures.houndLines.filterNot { it.text == "pation." }), false)
    assertEquals("occu", p.flushCarry())
    assertNull(p.flushCarry())
  }
}
