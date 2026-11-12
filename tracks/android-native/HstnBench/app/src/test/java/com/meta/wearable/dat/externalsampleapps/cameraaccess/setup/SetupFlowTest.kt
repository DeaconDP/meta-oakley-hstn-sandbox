package com.meta.wearable.dat.externalsampleapps.cameraaccess.setup

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SetupFlowTest {

  private fun SetupFlow.granted() = apply { permissions(PermState.GRANTED, PermState.GRANTED) }

  private fun say(line: SetupLine, then: Next = Next.LISTEN) = listOf(SetupAction.Say(line, then))

  @Test
  fun welcomeThenConnectHandsOffToMetaAi() {
    val flow = SetupFlow().granted()
    assertEquals(say(SetupLine.WELCOME), flow.ready(0))
    assertEquals(say(SetupLine.HANDOFF, Next.START_REGISTRATION), flow.heard("connect", 1_000))
  }

  @Test
  fun welcomeSaysWhatIsMissing() {
    val noMic = SetupFlow().apply { permissions(PermState.GRANTED, PermState.BLOCKED) }
    assertEquals(say(SetupLine.WELCOME_NO_MIC), noMic.ready(0))
    val noBluetooth = SetupFlow().apply { permissions(PermState.ASKABLE, PermState.GRANTED) }
    assertEquals(say(SetupLine.WELCOME_NO_BLUETOOTH), noBluetooth.ready(0))
  }

  @Test
  fun connectWithoutNearbyDevicesAsksOrPointsToSettings() {
    val askable = SetupFlow().apply { permissions(PermState.ASKABLE, PermState.GRANTED) }
    askable.ready(0)
    assertEquals(say(SetupLine.NEEDS_BLUETOOTH_ASK, Next.ASK_PERMISSIONS), askable.heard("connect", 1))
    val blocked = SetupFlow().apply { permissions(PermState.BLOCKED, PermState.GRANTED) }
    blocked.ready(0)
    assertEquals(say(SetupLine.NEEDS_BLUETOOTH_SETTINGS), blocked.heard("set up", 1))
    assertEquals(say(SetupLine.OPENING_SETTINGS, Next.OPEN_SETTINGS), blocked.heard("open settings", 2))
  }

  @Test
  fun comingBackUnregisteredOffersARetry() {
    val flow = SetupFlow().granted()
    flow.ready(0)
    flow.heard("yes", 1_000)
    flow.registrationStarted(5_000)
    flow.leftApp()
    // Away in Meta AI for a minute: no "didn't open" while away.
    assertTrue(flow.tick(60_000, busy = true).isEmpty())
    assertEquals(say(SetupLine.NOT_CONNECTED_YET), flow.returned(65_000))
    assertEquals(say(SetupLine.HANDOFF, Next.START_REGISTRATION), flow.heard("try again", 66_000))
  }

  @Test
  fun metaAiNeverOpeningIsSpoken() {
    val flow = SetupFlow(handoffTimeoutMs = 10_000).granted()
    flow.ready(0)
    flow.registrationStarted(1_000)
    assertEquals(say(SetupLine.ALREADY_CONNECTING), flow.heard("connect", 2_000))
    assertTrue(flow.tick(10_000, busy = false).isEmpty())
    assertEquals(say(SetupLine.DIDNT_OPEN), flow.tick(11_500, busy = false))
    assertTrue(!flow.isHandingOff)
  }

  @Test
  fun returningWithoutAHandoffIsAShortReminder() {
    val flow = SetupFlow().granted()
    flow.ready(0)
    flow.leftApp()
    assertEquals(say(SetupLine.RESUMED), flow.returned(30_000))
  }

  @Test
  fun helpRepeatQuitDecline() {
    val flow = SetupFlow().granted()
    flow.ready(0)
    assertEquals(say(SetupLine.HELP), flow.heard("what can I say", 1_000))
    assertEquals(say(SetupLine.HELP), flow.heard("repeat", 2_000))
    assertEquals(say(SetupLine.DECLINED), flow.heard("don't connect", 3_000))
    assertEquals(say(SetupLine.GOODBYE, Next.QUIT), flow.heard("close the app", 4_000))
  }

  @Test
  fun repeatSkipsSorryAndReminders() {
    val flow = SetupFlow().granted()
    flow.ready(0)
    assertEquals(say(SetupLine.NOT_UNDERSTOOD), flow.heard("banana", 1_000))
    assertEquals(say(SetupLine.WELCOME), flow.heard("say that again", 2_000))
  }

  @Test
  fun notUnderstoodIsRateLimitedAndIgnoresChatter() {
    val flow = SetupFlow(notUnderstoodGapMs = 8_000).granted()
    flow.ready(0)
    assertEquals(say(SetupLine.NOT_UNDERSTOOD), flow.heard("banana", 1_000))
    assertTrue(flow.heard("apple", 3_000).isEmpty())
    assertEquals(say(SetupLine.NOT_UNDERSTOOD), flow.heard("pear", 10_000))
    assertTrue(flow.heard("and then she said the bus was late again today", 30_000).isEmpty())
  }

  @Test
  fun twoGentleRemindersThenSilence() {
    val flow = SetupFlow().granted()
    flow.ready(0)
    var t = 0L
    val said = mutableListOf<SetupLine>()
    while (t < 10 * 60_000L) {
      t += 1_000
      flow.tick(t, busy = false).forEach { said += (it as SetupAction.Say).line }
    }
    assertEquals(listOf(SetupLine.REMINDER, SetupLine.LAST_REMINDER), said)
    // Saying something starts the reminders over.
    flow.heard("help", t)
    assertEquals(say(SetupLine.REMINDER), flow.tick(t + SetupFlow.REMINDER_GAP_MS, busy = false))
  }

  @Test
  fun noRemindersWhileBusyOrWithoutAMic() {
    val flow = SetupFlow().apply { permissions(PermState.GRANTED, PermState.BLOCKED) }
    flow.ready(0)
    for (t in 1..300) assertTrue(flow.tick(t * 1_000L, busy = false).isEmpty())
    val busy = SetupFlow().granted()
    busy.ready(0)
    for (t in 1..300) assertTrue(busy.tick(t * 1_000L, busy = true).isEmpty())
  }

  @Test
  fun errorsAreSpokenThenListening() {
    val flow = SetupFlow().granted()
    assertEquals(listOf(SetupAction.Say(SetupLine.TEXT, Next.LISTEN, "Oops")), flow.error("Oops"))
  }
}
