package com.meta.wearable.dat.externalsampleapps.cameraaccess.book

import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.BatteryLevel
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.EchoGuard
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.GlassesSnapshot
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.HealthAlert
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.HealthMonitor
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.Heat
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.IdleNudge
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.PhoneSnapshot

import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.HealthAlert.BluetoothOff
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.HealthAlert.BluetoothOn
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.HealthAlert.GlassesBattery
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.HealthAlert.GlassesConnected
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.HealthAlert.GlassesCooled
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.HealthAlert.GlassesDisconnected
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.HealthAlert.GlassesHot
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.HealthAlert.GlassesRemoved
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.HealthAlert.GlassesTooHot
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.HealthAlert.GlassesWornAgain
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.HealthAlert.NoGlassesPaired
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.HealthAlert.PhoneBattery
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.HealthAlert.UpdateRequired
import kotlin.random.Random
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HealthMonitorTest {

  private val ok = GlassesSnapshot(paired = true, connected = true, worn = true, battery = 80)
  private val phone = PhoneSnapshot(bluetoothOn = true, battery = 90)

  @Test
  fun healthyStartSaysNothing() {
    assertEquals(emptyList<HealthAlert>(), HealthMonitor().update(ok, phone))
  }

  @Test
  fun bluetoothOffExplainsItselfAndNothingElse() {
    val m = HealthMonitor()
    m.update(ok, phone)
    val off = m.update(ok.copy(connected = false, paired = false), phone.copy(bluetoothOn = false))
    assertEquals(listOf(BluetoothOff), off)
    val on = m.update(ok, phone)
    assertEquals(listOf(BluetoothOn, GlassesConnected), on)
  }

  @Test
  fun noGlassesLinked() {
    assertEquals(
        listOf(NoGlassesPaired),
        HealthMonitor().update(GlassesSnapshot(paired = false, connected = false), phone),
    )
  }

  @Test
  fun disconnectAndReconnectOnce() {
    val m = HealthMonitor()
    m.update(ok, phone)
    assertEquals(listOf(GlassesDisconnected), m.update(ok.copy(connected = false), phone))
    assertEquals(emptyList<HealthAlert>(), m.update(ok.copy(connected = false), phone))
    assertEquals(listOf(GlassesConnected), m.update(ok, phone))
  }

  @Test
  fun startingDisconnectedIsReported() {
    assertEquals(listOf(GlassesDisconnected), HealthMonitor().update(ok.copy(connected = false), phone))
  }

  @Test
  fun takenOffAndPutBackOn() {
    val m = HealthMonitor()
    m.update(ok, phone)
    assertEquals(listOf(GlassesRemoved), m.update(ok.copy(worn = false), phone))
    assertEquals(listOf(GlassesWornAgain), m.update(ok, phone))
    // Unknown wear state is not a removal.
    assertEquals(emptyList<HealthAlert>(), m.update(ok.copy(worn = null), phone))
  }

  @Test
  fun batteryWarnsOncePerThresholdAndRearmsOnCharge() {
    val m = HealthMonitor()
    m.update(ok, phone)
    assertEquals(listOf(GlassesBattery(20, BatteryLevel.LOW)), m.update(ok.copy(battery = 20), phone))
    assertEquals(emptyList<HealthAlert>(), m.update(ok.copy(battery = 18), phone))
    assertEquals(listOf(GlassesBattery(9, BatteryLevel.VERY_LOW)), m.update(ok.copy(battery = 9), phone))
    assertEquals(listOf(GlassesBattery(5, BatteryLevel.CRITICAL)), m.update(ok.copy(battery = 5), phone))
    assertEquals(emptyList<HealthAlert>(), m.update(ok.copy(battery = 4), phone))
    // Charging re-arms.
    m.update(ok.copy(battery = 6, charging = true), phone)
    assertEquals(
        listOf(GlassesBattery(6, BatteryLevel.VERY_LOW)),
        m.update(ok.copy(battery = 6, charging = false), phone),
    )
  }

  @Test
  fun phoneBatteryToo() {
    val m = HealthMonitor()
    m.update(ok, phone)
    assertEquals(
        listOf(PhoneBattery(10, BatteryLevel.VERY_LOW)),
        m.update(ok, phone.copy(battery = 10)),
    )
  }

  @Test
  fun heat() {
    val m = HealthMonitor()
    m.update(ok, phone)
    assertEquals(listOf(GlassesHot), m.update(ok.copy(heat = Heat.HOT), phone))
    assertEquals(listOf(GlassesTooHot), m.update(ok.copy(heat = Heat.TOO_HOT), phone))
    assertEquals(listOf(GlassesCooled), m.update(ok.copy(heat = Heat.HOT), phone))
    assertEquals(listOf(GlassesCooled), m.update(ok.copy(heat = Heat.NORMAL), phone))
  }

  @Test
  fun updateRequiredOnce() {
    val m = HealthMonitor()
    assertEquals(listOf(UpdateRequired), m.update(ok.copy(updateRequired = true), phone))
    assertEquals(emptyList<HealthAlert>(), m.update(ok.copy(updateRequired = true), phone))
  }
}

class ImageCheckTest {

  private val w = 48
  private val h = 72

  /** A page of print: paper ~210 with ~12% ink points ~40, plus sensor noise. */
  private fun page(seed: Int = 1, paper: Int = 210, ink: Int = 40): IntArray {
    val r = Random(seed)
    return IntArray(w * h) { (if (r.nextFloat() < 0.12f) ink else paper) + r.nextInt(-6, 7) }
  }

  private fun flat(level: Int, seed: Int = 2): IntArray {
    val r = Random(seed)
    return IntArray(w * h) { (level + r.nextInt(-4, 5)).coerceIn(0, 255) }
  }

  @Test
  fun aPageIsFine() = assertNull(ImageCheck.check(page(), w, h))

  @Test
  fun aSmallPageOnADarkTableIsNotTooDark() {
    val img = flat(35)
    val p = page()
    // Page fills the middle third.
    for (y in h / 3 until 2 * h / 3) for (x in w / 3 until 2 * w / 3) img[y * w + x] = p[y * w + x]
    val issue = ImageCheck.check(img, w, h)
    assertTrue("got $issue", issue == null || !issue.blocksOcr)
  }

  @Test
  fun lensCovered() = assertEquals(ImageIssue.COVERED, ImageCheck.check(flat(8), w, h))

  @Test
  fun dimRoom() =
      assertEquals(ImageIssue.TOO_DARK, ImageCheck.check(page(paper = 60, ink = 20), w, h))

  @Test
  fun wall() = assertEquals(ImageIssue.NOTHING_IN_VIEW, ImageCheck.check(flat(150), w, h))

  @Test
  fun glare() {
    val img = page()
    for (i in 0 until img.size * 4 / 10) img[i] = 255
    assertEquals(ImageIssue.GLARE, ImageCheck.check(img, w, h))
  }

  @Test
  fun handOverHalfThePage() {
    val img = page()
    val r = Random(3)
    for (y in 0 until h) for (x in 0 until w / 2) img[y * w + x] = 55 + r.nextInt(-10, 11)
    assertEquals(ImageIssue.PARTLY_BLOCKED, ImageCheck.check(img, w, h))
  }

  @Test
  fun imageHintOnlyReplacesNoTextHints() {
    assertTrue(ImageCheck.explainsFramingFailure(ImageIssue.GLARE, listOf(FramingIssue.NO_TEXT)))
    assertFalse(
        ImageCheck.explainsFramingFailure(ImageIssue.PARTLY_BLOCKED, listOf(FramingIssue.CUT_RIGHT)),
    )
    assertFalse(ImageCheck.explainsFramingFailure(null, listOf(FramingIssue.NO_TEXT)))
  }
}
