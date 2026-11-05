// IdleNudge - when to remind a quiet user what to say next
//
// A blind reader who has finished a page (or just opened the reader) and says nothing may not know
// the reader is waiting for them. After a stretch of quiet, the reader says what it's waiting for.
// The gaps grow (30 s, 60 s, 2 min by default) and then it stops, so a user who has put the book
// down isn't nagged. Anything the user does starts the count again from the first, short gap.
//
// "Quiet" means quiet on both sides: while the reader is busy (speaking, capturing, retrying) the
// caller reports [busy], which restarts the gap without using up a reminder.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.book

class IdleNudge(private val gapsMs: List<Long> = listOf(30_000L, 60_000L, 120_000L)) {

  private var quietSinceMs = 0L
  private var given = 0

  /** The user said or pressed something: reminders start over from the first gap. */
  @Synchronized
  fun userActed(nowMs: Long) {
    quietSinceMs = nowMs
    given = 0
  }

  /** The reader is busy, or not waiting for the user: the silence hasn't started yet. */
  @Synchronized
  fun busy(nowMs: Long) {
    quietSinceMs = nowMs
  }

  /**
   * Call while the reader is waiting for the user. Returns the reminder to give now (0 = first), or
   * null if it isn't time yet or all reminders have been given.
   */
  @Synchronized
  fun due(nowMs: Long): Int? {
    if (given >= gapsMs.size) return null
    if (nowMs - quietSinceMs < gapsMs[given]) return null
    quietSinceMs = nowMs
    return given++
  }

  /** True for the final reminder, after which the reader stays quiet until the user acts. */
  fun isLast(reminder: Int): Boolean = reminder == gapsMs.lastIndex
}
