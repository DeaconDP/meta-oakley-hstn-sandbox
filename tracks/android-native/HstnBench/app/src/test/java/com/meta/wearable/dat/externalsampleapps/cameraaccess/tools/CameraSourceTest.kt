// CameraSourceTest - which camera the tools use (glasses optional, notes/phone-camera.md)
//
// The rules (AUTO / PHONE / GLASSES, registered or not, the link-timeout fallback, when setup shows
// and when Bluetooth is asked for), the selector that forwards to the camera in use (with fake
// cameras), the phone camera's spoken wording, and the "torch on" hint.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools

import android.graphics.Bitmap
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.CameraSource
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.CameraSourceRules
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.CameraSourceSetting
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.DarkWatch
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.PhoneCameraProblem
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.PhoneCameraWording
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraSourceTest {

  private class FakeCamera : PageCamera {
    val streaming = MutableStateFlow(false)
    override val isStreaming = streaming
    override val link = MutableStateFlow(CameraLink.DISCONNECTED)
    val motionFlow = MutableSharedFlow<Float>(extraBufferCapacity = 16)
    override val motion: Flow<Float> = motionFlow
    var locked = false

    override suspend fun capturePage(): Bitmap? = null

    override fun frames(maxFps: Float): Flow<Bitmap> = emptyFlow()

    override suspend fun latestFrame(maxAgeMs: Long, timeoutMs: Long): Bitmap? = null

    override fun lockExposure(locked: Boolean) {
      this.locked = locked
    }
  }

  private val scope = CoroutineScope(Dispatchers.Unconfined + Job())
  private val glasses = FakeCamera()
  private val phone = FakeCamera()
  private val setting = MutableStateFlow(CameraSourceSetting.AUTO)
  private val registered = MutableStateFlow(false)

  private fun selector() = CameraSourceSelector(scope, glasses, phone, setting, registered)

  @After fun tearDown() = scope.cancel()

  // MARK: - Rules

  @Test
  fun autoUsesThePhoneUntilRegisteredThenTheGlasses() {
    assertEquals(CameraSource.PHONE, CameraSourceRules.resolve(CameraSourceSetting.AUTO, registered = false, override = null))
    assertEquals(CameraSource.GLASSES, CameraSourceRules.resolve(CameraSourceSetting.AUTO, registered = true, override = null))
  }

  @Test
  fun phoneAndGlassesSettingsAreHonoured() {
    for (reg in listOf(true, false)) {
      assertEquals(CameraSource.PHONE, CameraSourceRules.resolve(CameraSourceSetting.PHONE, reg, null))
      // GLASSES means glasses even before registration (setup then says what to do).
      assertEquals(CameraSource.GLASSES, CameraSourceRules.resolve(CameraSourceSetting.GLASSES, reg, null))
    }
  }

  @Test
  fun aVoiceSwitchWinsButNeverToUnregisteredGlasses() {
    assertEquals(CameraSource.PHONE, CameraSourceRules.resolve(CameraSourceSetting.GLASSES, true, CameraSource.PHONE))
    assertEquals(CameraSource.GLASSES, CameraSourceRules.resolve(CameraSourceSetting.PHONE, true, CameraSource.GLASSES))
    assertEquals(CameraSource.PHONE, CameraSourceRules.resolve(CameraSourceSetting.AUTO, false, CameraSource.GLASSES))
  }

  @Test
  fun onlyAutoWithNoSwitchFallsBackToThePhone() {
    assertTrue(CameraSourceRules.fallBackToPhone(CameraSourceSetting.AUTO, null, CameraSource.GLASSES, glassesStreaming = false))
    assertFalse(CameraSourceRules.fallBackToPhone(CameraSourceSetting.AUTO, null, CameraSource.GLASSES, glassesStreaming = true))
    assertFalse(CameraSourceRules.fallBackToPhone(CameraSourceSetting.GLASSES, null, CameraSource.GLASSES, false))
    assertFalse(CameraSourceRules.fallBackToPhone(CameraSourceSetting.AUTO, CameraSource.GLASSES, CameraSource.GLASSES, false))
    assertFalse(CameraSourceRules.fallBackToPhone(CameraSourceSetting.AUTO, null, CameraSource.PHONE, false))
  }

  @Test
  fun setupShowsOnlyUntilACameraIsChosen() {
    // First run: not registered, nothing chosen.
    assertTrue(CameraSourceRules.showSetup(registered = false, CameraSourceSetting.AUTO, phoneChosen = false))
    // "Use my phone" on the setup screen, or the PHONE setting: straight to the tools.
    assertFalse(CameraSourceRules.showSetup(false, CameraSourceSetting.AUTO, phoneChosen = true))
    assertFalse(CameraSourceRules.showSetup(false, CameraSourceSetting.PHONE, phoneChosen = false))
    // The GLASSES setting needs registration.
    assertTrue(CameraSourceRules.showSetup(false, CameraSourceSetting.GLASSES, phoneChosen = true))
    for (s in CameraSourceSetting.entries) assertFalse(CameraSourceRules.showSetup(true, s, false))
  }

  @Test
  fun bluetoothIsAskedForOnlyOnTheGlassesPath() {
    assertFalse(CameraSourceRules.needsBluetooth(CameraSourceSetting.AUTO, connectAsked = false))
    assertFalse(CameraSourceRules.needsBluetooth(CameraSourceSetting.PHONE, connectAsked = false))
    assertTrue(CameraSourceRules.needsBluetooth(CameraSourceSetting.AUTO, connectAsked = true))
    assertTrue(CameraSourceRules.needsBluetooth(CameraSourceSetting.GLASSES, connectAsked = false))
  }

  @Test
  fun settingNamesRoundTrip() {
    for (s in CameraSourceSetting.entries) assertEquals(s, CameraSourceSetting.fromName(s.name))
    assertEquals(CameraSourceSetting.AUTO, CameraSourceSetting.fromName(null))
    assertEquals(CameraSourceSetting.AUTO, CameraSourceSetting.fromName("nonsense"))
  }

  // MARK: - Selector

  @Test
  fun theSelectorFollowsRegistrationAndTheSetting() {
    val sel = selector()
    assertEquals(CameraSource.PHONE, sel.source.value)
    registered.value = true
    assertEquals(CameraSource.GLASSES, sel.source.value)
    setting.value = CameraSourceSetting.PHONE
    assertEquals(CameraSource.PHONE, sel.source.value)
    assertTrue(sel.usingPhone)
  }

  @Test
  fun streamingStateFollowsASwitch() {
    registered.value = true
    phone.streaming.value = true
    val sel = selector()
    assertEquals(CameraSource.GLASSES, sel.source.value)
    assertFalse(sel.isStreaming.value)
    sel.use(CameraSource.PHONE)
    assertEquals(CameraSource.PHONE, sel.source.value)
    assertTrue(sel.isStreaming.value)
    // The saved setting changing clears the voice switch.
    setting.value = CameraSourceSetting.GLASSES
    assertEquals(CameraSource.GLASSES, sel.source.value)
    assertFalse(sel.isStreaming.value)
  }

  @Test
  fun aToolCollectingMotionKeepsGoingAcrossASwitch() {
    registered.value = true
    val sel = selector()
    val got = mutableListOf<Float>()
    val job = scope.launch { sel.motion.collect { got += it } }
    glasses.motionFlow.tryEmit(0.1f)
    sel.use(CameraSource.PHONE)
    phone.motionFlow.tryEmit(0.7f)
    glasses.motionFlow.tryEmit(0.9f) // the old camera no longer counts
    job.cancel()
    assertEquals(listOf(0.1f, 0.7f), got)
  }

  @Test
  fun theGlassesNotComingUpFallsBackToThePhoneUnderAuto() = runBlocking {
    registered.value = true
    val sel = selector()
    assertEquals(CameraSourceSelector.Outcome.FELL_BACK, sel.awaitStreaming(50))
    assertEquals(CameraSource.PHONE, sel.source.value)
    assertTrue(sel.fellBack)
    // "Use the glasses" afterwards wins, and doesn't fall back again.
    sel.use(CameraSource.GLASSES)
    assertEquals(CameraSourceSelector.Outcome.DOWN, sel.awaitStreaming(50))
    assertEquals(CameraSource.GLASSES, sel.source.value)
  }

  @Test
  fun theGlassesSettingWaitsForTheGlassesInstead() = runBlocking {
    registered.value = true
    setting.value = CameraSourceSetting.GLASSES
    val sel = selector()
    assertEquals(CameraSourceSelector.Outcome.DOWN, sel.awaitStreaming(50))
    assertEquals(CameraSource.GLASSES, sel.source.value)
    glasses.streaming.value = true
    assertEquals(CameraSourceSelector.Outcome.UP, sel.awaitStreaming(50))
  }

  @Test
  fun thePhoneComingUpIsUp() = runBlocking {
    val sel = selector()
    assertEquals(CameraSourceSelector.Outcome.DOWN, sel.awaitStreaming(20))
    phone.streaming.value = true
    assertEquals(CameraSourceSelector.Outcome.UP, sel.awaitStreaming(20))
  }

  @Test
  fun anExposureLockMovesWithTheSource() {
    registered.value = true
    val sel = selector()
    sel.lockExposure(true)
    assertTrue(glasses.locked)
    sel.use(CameraSource.PHONE)
    assertFalse(glasses.locked)
    assertTrue(phone.locked)
    sel.lockExposure(false)
    assertFalse(phone.locked)
  }

  // MARK: - What the phone camera says

  @Test
  fun eachPhoneProblemHasItsOwnFix() {
    val lines = (PhoneCameraProblem.entries.map { PhoneCameraWording.problem(it) } + PhoneCameraWording.problem(null))
    assertEquals(lines.size, lines.toSet().size)
    assertTrue(PhoneCameraWording.problem(PhoneCameraProblem.PERMISSION_BLOCKED).contains("Settings"))
    assertTrue(PhoneCameraWording.problem(PhoneCameraProblem.PERMISSION_DENIED).contains("use the phone"))
    assertTrue(PhoneCameraWording.problem(PhoneCameraProblem.IN_USE).contains("Another app"))
    for (l in lines) {
      assertFalse("no glasses talk on the phone: $l", l.contains("glasses", ignoreCase = true))
      assertTrue("a full sentence: $l", l.endsWith("."))
    }
  }

  @Test
  fun phoneLinesSayWhatToSayNext() {
    assertTrue(PhoneCameraWording.TOO_DARK.contains("torch on"))
    assertTrue(PhoneCameraWording.CAMERA_OFF.contains("connect"))
    assertTrue(PhoneCameraWording.GLASSES_NOT_SET_UP.contains("connect my glasses"))
    assertEquals("Glasses not connected. Using the phone camera.", PhoneCameraWording.FELL_BACK)
    assertEquals("Using the phone camera. It's on.", PhoneCameraWording.which(CameraSource.PHONE, streaming = true))
    assertNotEquals(
        PhoneCameraWording.which(CameraSource.GLASSES, true),
        PhoneCameraWording.which(CameraSource.GLASSES, false),
    )
    // Reading tools say where to hold the phone; the others don't.
    assertTrue(PhoneCameraWording.ready(ToolId.BOOK).contains("30 centimetres"))
    assertTrue(PhoneCameraWording.ready(ToolId.MAIL).contains("30 centimetres"))
    assertFalse(PhoneCameraWording.ready(ToolId.LIGHT).contains("centimetres"))
    assertEquals(PhoneCameraWording.CAMERA_ON, PhoneCameraWording.ready(null))
    assertEquals("Camera: automatic, using the phone.", PhoneCameraWording.setting(CameraSourceSetting.AUTO, CameraSource.PHONE))
    assertEquals("Camera: glasses, using the phone for now.", PhoneCameraWording.setting(CameraSourceSetting.GLASSES, CameraSource.PHONE))
  }

  // MARK: - "Torch on" hint

  @Test
  fun darknessSuggestsTheTorchOnceAfterAHold() {
    val w = DarkWatch(holdMs = 3_000)
    assertFalse(w.update(5f, 0, torchOn = false))
    assertFalse(w.update(5f, 2_000, torchOn = false))
    assertTrue(w.update(5f, 3_000, torchOn = false))
    assertFalse(w.update(5f, 9_000, torchOn = false))
    // Bright again re-arms it.
    assertFalse(w.update(120f, 10_000, torchOn = false))
    assertFalse(w.update(5f, 11_000, torchOn = false))
    assertTrue(w.update(5f, 14_000, torchOn = false))
  }

  @Test
  fun dimButNotDarkOrTorchOnSaysNothing() {
    val w = DarkWatch(holdMs = 1_000)
    for (t in 0L..10_000L step 500) assertFalse(w.update(30f, t, torchOn = false))
    for (t in 0L..10_000L step 500) assertFalse(w.update(3f, t, torchOn = true))
  }
}
