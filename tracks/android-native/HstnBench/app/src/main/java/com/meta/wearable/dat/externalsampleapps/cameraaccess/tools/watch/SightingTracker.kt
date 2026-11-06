// SightingTracker - when to speak while watching, so the user hears each sighting once
//
// OCR runs on every frame (1-2 a second), but the user should hear "42, on your right" once when it
// comes into view, "gone" once when it has been out of view for a few seconds, and again only if it
// comes back. A single frame is never enough: the target must be found in at least [need] of the
// last [window] frames before it's announced, so one misread frame doesn't raise a false alarm.
// Near misses ("I see 24, not 42") need the same two-frame agreement and are said at most every
// [nearMissGapMs], the same near miss at most every [sameNearMissGapMs], and never while the target
// is in view. [where] answers "where is it?" from the last sighting.
//
// Also here: [Position] turns a sighting's place in the frame into left / ahead / right and close /
// far, and two small watchers for the frame loop, [ViewIssueWatch] (lens covered, too dark: said when
// it starts, repeated now and then, and "I can see again" when it clears) and [PaceWatch] (OCR can't
// keep up). Times are milliseconds from any monotonic clock. Pure Kotlin, JVM-tested.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.watch

/** Something the user should hear. */
sealed interface WatchEvent {
  data class Appeared(val spot: Spot) : WatchEvent

  data object Gone : WatchEvent

  data class NearMiss(val seen: String) : WatchEvent
}

/** The answer to "where is it?". */
sealed interface WhereAnswer {
  data class InView(val spot: Spot) : WhereAnswer

  data class LastSeen(val spot: Spot, val agoMs: Long) : WhereAnswer

  data object NotSeen : WhereAnswer
}

class SightingTracker(
    private val window: Int = 4,
    private val need: Int = 2,
    /** Out of view for this long before "gone". */
    private val goneAfterMs: Long = 4_000L,
    /** Frames older than this don't count towards [need] (slow OCR). */
    private val maxAgeMs: Long = 8_000L,
    private val nearMissGapMs: Long = 20_000L,
    private val sameNearMissGapMs: Long = 60_000L,
) {
  private class Frame(val atMs: Long, val hit: Boolean, val nearMiss: String?)

  private val recent = ArrayDeque<Frame>()

  var inView: Boolean = false
    private set

  private var lastSpot: Spot? = null
  private var lastSeenMs: Long = 0L
  private var lastNearMissMs: Long = Long.MIN_VALUE / 2
  private val nearMissSaid = mutableMapOf<String, Long>()

  /** Forget everything (new target, or the stream came back after a gap). */
  fun reset() {
    recent.clear()
    inView = false
    lastSpot = null
    nearMissSaid.clear()
    lastNearMissMs = Long.MIN_VALUE / 2
  }

  /** One frame's result at [nowMs]. Returns what to say, usually nothing. */
  fun onFrame(nowMs: Long, match: FrameMatch): List<WatchEvent> {
    recent.addLast(Frame(nowMs, match.hit != null, match.nearMiss))
    while (recent.size > window) recent.removeFirst()
    while (recent.isNotEmpty() && nowMs - recent.first().atMs > maxAgeMs) recent.removeFirst()

    val events = mutableListOf<WatchEvent>()
    val hit = match.hit
    if (hit != null) {
      if (!inView && recent.count { it.hit } >= need) {
        inView = true
        events += WatchEvent.Appeared(hit)
      }
      if (inView) {
        lastSpot = hit
        lastSeenMs = nowMs
      }
      return events
    }

    if (inView && nowMs - lastSeenMs >= goneAfterMs) {
      inView = false
      // Old hits mustn't help a single new frame count as "back".
      recent.clear()
      events += WatchEvent.Gone
    }

    val near = match.nearMiss
    if (near != null && !inView) {
      val agreed = recent.count { it.nearMiss == near } >= need
      val sameOk = nowMs - (nearMissSaid[near] ?: (Long.MIN_VALUE / 2)) >= sameNearMissGapMs
      if (agreed && sameOk && nowMs - lastNearMissMs >= nearMissGapMs) {
        lastNearMissMs = nowMs
        nearMissSaid[near] = nowMs
        events += WatchEvent.NearMiss(near)
      }
    }
    return events
  }

  fun where(nowMs: Long): WhereAnswer {
    val spot = lastSpot ?: return WhereAnswer.NotSeen
    if (!inView) return WhereAnswer.LastSeen(spot, nowMs - lastSeenMs)
    return WhereAnswer.InView(spot)
  }
}

enum class Side { LEFT, AHEAD, RIGHT }

enum class Nearness { CLOSE, FAR }

object Position {
  /**
   * Where straight ahead of the wearer falls in the frame. The camera sits at the front left of the
   * glasses, so something straight ahead is a little right of the picture's centre (most for
   * nearby things). An estimate; unverified on real glasses.
   */
  const val CAMERA_CENTRE_X = 0.53f

  /** How far from [CAMERA_CENTRE_X] still counts as "ahead". The portrait frame is narrow. */
  const val AHEAD_HALF_WIDTH = 0.16f

  /** Text at least this share of the frame's height is "close"; this small or less, "far". */
  const val CLOSE_HEIGHT = 0.10f
  const val FAR_HEIGHT = 0.025f

  fun side(x: Float): Side =
      when {
        x < CAMERA_CENTRE_X - AHEAD_HALF_WIDTH -> Side.LEFT
        x > CAMERA_CENTRE_X + AHEAD_HALF_WIDTH -> Side.RIGHT
        else -> Side.AHEAD
      }

  fun nearness(heightFraction: Float): Nearness? =
      when {
        heightFraction >= CLOSE_HEIGHT -> Nearness.CLOSE
        heightFraction <= FAR_HEIGHT -> Nearness.FAR
        else -> null
      }
}

/** A problem with the picture that stops reading (lens covered, too dark). */
enum class ViewIssue { COVERED, TOO_DARK }

sealed interface ViewIssueEvent {
  data class Started(val issue: ViewIssue) : ViewIssueEvent

  data class StillThere(val issue: ViewIssue) : ViewIssueEvent

  data object Cleared : ViewIssueEvent
}

/** Says a view problem once it lasts [confirmFrames] frames, repeats it every [repeatMs], and says when it clears. */
class ViewIssueWatch(private val confirmFrames: Int = 2, private val repeatMs: Long = 45_000L) {
  private var candidate: ViewIssue? = null
  private var count = 0
  private var clearCount = 0
  var current: ViewIssue? = null
    private set
  private var saidMs = 0L

  fun reset() {
    candidate = null
    count = 0
    clearCount = 0
    current = null
  }

  fun onFrame(nowMs: Long, issue: ViewIssue?): ViewIssueEvent? {
    if (issue == null) {
      candidate = null
      count = 0
      if (current == null) return null
      clearCount++
      if (clearCount < confirmFrames) return null
      current = null
      clearCount = 0
      return ViewIssueEvent.Cleared
    }
    clearCount = 0
    if (current != null) {
      // Covered and dark look alike; keep the one we said unless it's been a while.
      if (nowMs - saidMs >= repeatMs) {
        current = issue
        saidMs = nowMs
        return ViewIssueEvent.StillThere(issue)
      }
      return null
    }
    if (issue == candidate) count++ else {
      candidate = issue
      count = 1
    }
    if (count < confirmFrames) return null
    current = issue
    saidMs = nowMs
    return ViewIssueEvent.Started(issue)
  }
}

/**
 * Is OCR keeping up? [onFrameDone] after each processed frame. Returns the seconds between frames
 * once (and again after it recovered) when the average gap over [samples] frames exceeds [slowMs].
 */
class PaceWatch(private val slowMs: Long = 3_000L, private val samples: Int = 4) {
  private val gaps = ArrayDeque<Long>()
  private var lastMs: Long? = null
  private var warned = false

  fun reset() {
    gaps.clear()
    lastMs = null
  }

  val averageGapMs: Long?
    get() = if (gaps.isEmpty()) null else gaps.sum() / gaps.size

  fun onFrameDone(nowMs: Long): Int? {
    lastMs?.let { gaps.addLast(nowMs - it) }
    lastMs = nowMs
    while (gaps.size > samples) gaps.removeFirst()
    if (gaps.size < samples) return null
    val avg = gaps.sum() / gaps.size
    if (avg > slowMs && !warned) {
      warned = true
      return ((avg + 500) / 1000).toInt()
    }
    if (avg < slowMs * 2 / 3) warned = false
    return null
  }
}
