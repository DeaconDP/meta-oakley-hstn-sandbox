package com.meta.wearable.dat.externalsampleapps.cameraaccess.book

import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.BatteryLevel
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.EchoGuard
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.GlassesSnapshot
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.HealthMonitor
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.Heat
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.IdleNudge
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.PhoneSnapshot

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class IdleNudgeTest {

  private val nudge = IdleNudge(listOf(30L, 60L, 120L))

  @Test
  fun remindsAfterGrowingGapsThenStops() {
    nudge.userActed(0)
    assertNull(nudge.due(29))
    assertEquals(0, nudge.due(30))
    assertNull(nudge.due(89))
    assertEquals(1, nudge.due(90))
    assertNull(nudge.due(209))
    assertEquals(2, nudge.due(210))
    assertTrue(nudge.isLast(2))
    assertFalse(nudge.isLast(1))
    // All given: quiet from now on, however long it waits.
    assertNull(nudge.due(10_000))
  }

  @Test
  fun userActingStartsOverFromTheFirstGap() {
    nudge.userActed(0)
    assertEquals(0, nudge.due(30))
    assertEquals(1, nudge.due(90))
    nudge.userActed(100)
    assertNull(nudge.due(129))
    assertEquals(0, nudge.due(130))
  }

  @Test
  fun busyTimeDoesNotCountAsSilence() {
    nudge.userActed(0)
    // Reading or capturing for a long time, then waiting: the gap starts when the busy time ends.
    nudge.busy(500)
    assertNull(nudge.due(529))
    assertEquals(0, nudge.due(530))
    // Busy doesn't refund reminders already given.
    nudge.busy(600)
    assertEquals(1, nudge.due(660))
  }
}
