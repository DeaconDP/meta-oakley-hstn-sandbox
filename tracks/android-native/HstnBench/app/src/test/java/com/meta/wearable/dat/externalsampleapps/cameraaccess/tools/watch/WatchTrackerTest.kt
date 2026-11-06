// WatchTrackerTest - when Watch for text speaks, and the words it uses for where
//
// The sighting state machine (two of the last four frames before announcing, so one misread frame
// never raises an alarm; announce once; "gone" after a few seconds out of view; announce again on
// return), near-miss throttling, "where is it?", left / ahead / right with the camera's offset,
// close / far, the view-problem watcher (covered, dark, cleared) and the OCR pace watcher.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.watch

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WatchTrackerTest {

  private val seen = FrameMatch(Spot("42", 0.85f, 0.05f), null)
  private val nothing = FrameMatch.NONE

  private fun near(s: String) = FrameMatch(null, s)

  /** Feeds [frames] at 500 ms apart (2 fps) from [start]; returns every event with its time. */
  private fun SightingTracker.run(frames: List<FrameMatch>, start: Long = 0L, gap: Long = 500L): List<Pair<Long, WatchEvent>> =
      frames.flatMapIndexed { i, f -> onFrame(start + i * gap, f).map { (start + i * gap) to it } }

  @Test
  fun oneFrameIsNeverEnough() {
    val tr = SightingTracker()
    val events = tr.run(listOf(nothing, seen, nothing, nothing, nothing, seen, nothing, nothing, nothing, nothing))
    assertEquals(emptyList<Pair<Long, WatchEvent>>(), events)
  }

  @Test
  fun twoOfTheLastFourAnnounceOnce() {
    val tr = SightingTracker()
    val events = tr.run(listOf(nothing, seen, nothing, seen, seen, seen, seen, seen))
    assertEquals(1, events.size)
    assertEquals(1500L, events[0].first)
    assertTrue(events[0].second is WatchEvent.Appeared)
    assertTrue(tr.inView)
  }

  @Test
  fun appearGoneReappear() {
    val tr = SightingTracker(goneAfterMs = 4_000L)
    val frames = listOf(seen, seen) + List(12) { nothing } + listOf(seen, seen, seen)
    val events = tr.run(frames).map { it.second }
    assertEquals(3, events.size)
    assertTrue(events[0] is WatchEvent.Appeared)
    assertEquals(WatchEvent.Gone, events[1])
    assertTrue(events[2] is WatchEvent.Appeared)
  }

  @Test
  fun goneComesAfterTheDelayNotOnTheFirstMissedFrame() {
    val tr = SightingTracker(goneAfterMs = 4_000L)
    val events = tr.run(listOf(seen, seen) + List(12) { nothing })
    val gone = events.single { it.second == WatchEvent.Gone }
    // Last seen at 500 ms; gone at the first frame 4 s later.
    assertEquals(4_500L, gone.first)
  }

  @Test
  fun aBriefDropoutDoesntSayGone() {
    val tr = SightingTracker(goneAfterMs = 4_000L)
    val events = tr.run(listOf(seen, seen, nothing, nothing, nothing, seen, nothing, nothing, seen, seen))
    assertEquals(1, events.size)
  }

  @Test
  fun afterGoneASingleFrameDoesntCountAsBack() {
    val tr = SightingTracker(goneAfterMs = 2_000L)
    // Slow OCR: 2 s between frames, so old hits would still be in the window.
    val events = tr.run(listOf(seen, seen, nothing, nothing, seen, nothing), gap = 2_000L).map { it.second }
    assertEquals(2, events.size)
    assertEquals(WatchEvent.Gone, events[1])
  }

  @Test
  fun oldFramesAgeOut() {
    val tr = SightingTracker(maxAgeMs = 8_000L)
    // Two hits 10 s apart (very slow OCR, or a gap) are not two of the last four.
    assertEquals(emptyList<Pair<Long, WatchEvent>>(), tr.run(listOf(seen, seen), gap = 10_000L))
  }

  @Test
  fun nearMissesAgreeTwiceAndAreThrottled() {
    val tr = SightingTracker(nearMissGapMs = 20_000L, sameNearMissGapMs = 60_000L)
    // Once: not said.
    assertEquals(0, tr.run(listOf(near("24"), nothing, nothing, nothing)).size)
    // Twice: said once, not again for the next 20 s.
    val e1 = tr.run(List(30) { near("24") }, start = 10_000L)
    assertEquals(listOf<WatchEvent>(WatchEvent.NearMiss("24")), e1.map { it.second })
    // A different near miss within 20 s: still quiet; after 20 s: said.
    val e2 = tr.run(List(50) { near("43") }, start = 25_000L)
    assertEquals(1, e2.size)
    assertTrue(e2[0].first >= 10_500L + 20_000L)
    // The same one again within 60 s: quiet.
    val e3 = tr.run(List(20) { near("24") }, start = 55_000L)
    assertEquals(0, e3.size)
  }

  @Test
  fun noNearMissWhileTheTargetIsInView() {
    val tr = SightingTracker()
    tr.run(listOf(seen, seen))
    assertEquals(0, tr.run(listOf(near("24"), near("24"), near("24")), start = 1_000L).size)
  }

  @Test
  fun whereIsIt() {
    val tr = SightingTracker(goneAfterMs = 4_000L)
    assertEquals(WhereAnswer.NotSeen, tr.where(0L))
    // A single unconfirmed frame isn't a sighting.
    tr.onFrame(0L, seen)
    assertEquals(WhereAnswer.NotSeen, tr.where(100L))
    tr.onFrame(500L, seen)
    assertEquals(WhereAnswer.InView(seen.hit!!), tr.where(600L))
    tr.run(List(10) { nothing }, start = 1_000L)
    val last = tr.where(10_500L)
    assertTrue(last is WhereAnswer.LastSeen)
    assertEquals(10_000L, (last as WhereAnswer.LastSeen).agoMs)
    tr.reset()
    assertEquals(WhereAnswer.NotSeen, tr.where(11_000L))
  }

  @Test
  fun sidesAllowForTheCameraOnTheLeft() {
    assertEquals(Side.LEFT, Position.side(0.1f))
    assertEquals(Side.LEFT, Position.side(0.35f))
    assertEquals(Side.AHEAD, Position.side(0.5f))
    // The picture's centre-right is still straight ahead of the wearer.
    assertEquals(Side.AHEAD, Position.side(0.66f))
    assertEquals(Side.RIGHT, Position.side(0.72f))
    assertEquals(Side.RIGHT, Position.side(0.95f))
  }

  @Test
  fun closeAndFarFromTextHeight() {
    assertEquals(Nearness.CLOSE, Position.nearness(0.2f))
    assertEquals(Nearness.FAR, Position.nearness(0.01f))
    assertNull(Position.nearness(0.05f))
  }

  @Test
  fun viewProblemsAreSaidOnceThenRepeatedThenCleared() {
    val w = ViewIssueWatch(confirmFrames = 2, repeatMs = 45_000L)
    assertNull(w.onFrame(0, ViewIssue.COVERED))
    assertEquals(ViewIssueEvent.Started(ViewIssue.COVERED), w.onFrame(500, ViewIssue.COVERED))
    assertNull(w.onFrame(1_000, ViewIssue.COVERED))
    assertNull(w.onFrame(1_500, ViewIssue.TOO_DARK))
    assertEquals(ViewIssueEvent.StillThere(ViewIssue.TOO_DARK), w.onFrame(46_000, ViewIssue.TOO_DARK))
    assertNull(w.onFrame(46_500, null))
    assertEquals(ViewIssueEvent.Cleared, w.onFrame(47_000, null))
    assertNull(w.onFrame(47_500, null))
    // A single dark frame (a passing shadow) says nothing.
    assertNull(w.onFrame(48_000, ViewIssue.TOO_DARK))
    assertNull(w.onFrame(48_500, null))
  }

  @Test
  fun paceWarnsOnceWhenOcrCantKeepUp() {
    val p = PaceWatch(slowMs = 3_000L, samples = 4)
    var t = 0L
    repeat(10) {
      t += 500
      assertNull(p.onFrameDone(t))
    }
    val warnings = (1..10).mapNotNull {
      t += 4_000
      p.onFrameDone(t)
    }
    assertEquals(1, warnings.size)
    assertTrue(warnings[0] in 3..4)
    // Recovers, then slows again: warned again.
    repeat(10) {
      t += 500
      p.onFrameDone(t)
    }
    val again = (1..10).mapNotNull {
      t += 5_000
      p.onFrameDone(t)
    }
    assertEquals(1, again.size)
  }
}
