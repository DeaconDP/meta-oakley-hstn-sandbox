// HandsFreeTest - the mode rules, the hands-free entry points, and the glasses card's throttle
//
// notes/hands-free-mode.md: the toolbox is the default; TalkBack on first run starts hands-free (said
// once); speakup://handsfree, the shortcut and the extra switch it on; each mode turns the old
// always-on behaviours on or off as a set. The card is trimmed to a glance and sent only on change,
// at most about twice a second.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools

import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.CardDecision
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.CardThrottle
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.FirstRun
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.GlassesCard
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.HandsFreeIntent
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.HandsFreeLaunch
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.HandsFreePolicy
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.HandsFreeRules
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ModeChange
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ModeSettings
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.Verbosity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HandsFreeTest {

  // MARK: - Mode rules

  @Test
  fun theToolboxIsTheDefault() {
    assertFalse(ModeSettings().handsFree)
    assertTrue("glasses display defaults on (only used in hands-free)", ModeSettings().glassesDisplay)
    assertEquals(Verbosity.NORMAL, ModeSettings().verbosity)
    assertEquals(FirstRun(handsFree = false, announce = false), HandsFreeRules.firstRun(stored = null, screenReaderOn = false))
  }

  @Test
  fun firstRunWithTalkBackStartsHandsFreeAndSaysSoOnce() {
    assertEquals(FirstRun(handsFree = true, announce = true), HandsFreeRules.firstRun(stored = null, screenReaderOn = true))
    // After the first run the saved choice wins, whatever the screen reader does, and nothing is said.
    assertEquals(FirstRun(handsFree = false, announce = false), HandsFreeRules.firstRun(stored = false, screenReaderOn = true))
    assertEquals(FirstRun(handsFree = true, announce = false), HandsFreeRules.firstRun(stored = true, screenReaderOn = false))
  }

  @Test
  fun aHandsFreeLaunchSwitchesItOnAndKeepsItOn() {
    assertTrue(HandsFreeRules.afterLaunch(current = false, launchedHandsFree = true))
    assertTrue(HandsFreeRules.afterLaunch(current = true, launchedHandsFree = false))
    assertFalse(HandsFreeRules.afterLaunch(current = false, launchedHandsFree = false))
  }

  @Test
  fun eachSwitchSaysWhatHappened() {
    assertEquals(ModeChange.TURNED_ON, HandsFreeRules.change(was = false, wanted = true))
    assertEquals(ModeChange.TURNED_OFF, HandsFreeRules.change(was = true, wanted = false))
    assertEquals(ModeChange.ALREADY_ON, HandsFreeRules.change(was = true, wanted = true))
    assertEquals(ModeChange.ALREADY_OFF, HandsFreeRules.change(was = false, wanted = false))
  }

  @Test
  fun theToolboxTurnsEveryAlwaysOnBehaviourOff() {
    val toolbox = HandsFreePolicy(handsFree = false)
    assertFalse(toolbox.alwaysListening)
    assertFalse(toolbox.narrateStartup)
    assertFalse(toolbox.idleReminders)
    assertFalse(toolbox.replaceDialogs)
    assertFalse(toolbox.speakAlertsAtHome)
    assertFalse(toolbox.reconnectAtHome)
    assertFalse(toolbox.setupConversation)
    val handsFree = HandsFreePolicy(handsFree = true)
    assertTrue(handsFree.alwaysListening)
    assertTrue(handsFree.narrateStartup)
    assertTrue(handsFree.idleReminders)
    assertTrue(handsFree.replaceDialogs)
    assertTrue(handsFree.speakAlertsAtHome)
    assertTrue(handsFree.reconnectAtHome)
    assertTrue(handsFree.setupConversation)
  }

  @Test
  fun aToolLaunchedStraightInIsAVoiceFirstVisit() {
    // "Hey Google, open Mail Reader" listens and narrates even in the toolbox, without saving it.
    assertTrue(HandsFreeRules.effective(saved = false, voiceFirstToolLaunch = true).alwaysListening)
    assertFalse(HandsFreeRules.effective(saved = false, voiceFirstToolLaunch = false).alwaysListening)
    assertTrue(HandsFreeRules.effective(saved = true, voiceFirstToolLaunch = false).alwaysListening)
  }

  @Test
  fun verbositySurvivesAnUnknownSavedValue() {
    assertEquals(Verbosity.SHORT, Verbosity.fromName("SHORT"))
    assertEquals(Verbosity.NORMAL, Verbosity.fromName(null))
    assertEquals(Verbosity.NORMAL, Verbosity.fromName("chatty"))
  }

  // MARK: - Entry points

  @Test
  fun handsFreeEntryPoints() {
    assertTrue(HandsFreeLaunch.isHandsFree(HandsFreeIntent(scheme = "speakup", host = "handsfree")))
    assertTrue(HandsFreeLaunch.isHandsFree(HandsFreeIntent(scheme = "SpeakUp", host = "HandsFree")))
    assertTrue(HandsFreeLaunch.isHandsFree(HandsFreeIntent(handsFreeExtra = true)))
    // Other links and a plain launch don't.
    assertFalse(HandsFreeLaunch.isHandsFree(HandsFreeIntent()))
    assertFalse(HandsFreeLaunch.isHandsFree(HandsFreeIntent(scheme = "speakup", host = "mail")))
    assertFalse(HandsFreeLaunch.isHandsFree(HandsFreeIntent(scheme = "hstnbench", host = "handsfree")))
  }

  // MARK: - The glasses card

  @Test
  fun theCardIsAGlance() {
    val card =
        GlassesCard.of(
            screen = "Main menu",
            state = "Main menu. Say read my book, read my mail, labels, watch for text, light, or what can I say.",
            heard = "could you please tell me what the label on this tin of tomatoes says about allergens",
            hints = listOf("read my book", "read my mail", "help", "main menu", "help"),
        )
    assertEquals("Main menu.", card.state)
    assertTrue(card.heard, card.heard.length <= GlassesCard.MAX_HEARD)
    assertTrue(card.heard.endsWith("…"))
    assertEquals(listOf("read my book", "read my mail", "help"), card.hints)
    assertEquals("Say: read · next · main menu", GlassesCard.hintLine(listOf("read", "next", "main menu")))
    assertEquals("", GlassesCard.hintLine(emptyList()))
  }

  @Test
  fun shortenCutsAtAWord() {
    assertEquals("short", GlassesCard.shorten("  short ", 10))
    assertEquals("one two…", GlassesCard.shorten("one two three four", 10))
    assertEquals("Reading page 3", GlassesCard.firstSentence("Reading page 3"))
    assertEquals("1.5 times speed.", GlassesCard.firstSentence("1.5 times speed."))
  }

  @Test
  fun theThrottleSendsOnlyChangesAtMostTwiceASecond() {
    val t = CardThrottle(minGapMs = 500)
    val a = GlassesCard(screen = "Main menu", state = "Listening")
    val b = a.copy(heard = "read my mail")
    val c = a.copy(screen = "Mail reader")

    assertEquals(CardDecision.Send, t.offer(a, nowMs = 0))
    t.sent(a, nowMs = 0)
    // The same card again: nothing to send.
    assertEquals(CardDecision.Unchanged, t.offer(a, nowMs = 100))
    // A change 100 ms later waits out the gap...
    assertEquals(CardDecision.Later(400), t.offer(b, nowMs = 100))
    // ...and a newer change in the gap replaces it without a second timer.
    assertEquals(CardDecision.Unchanged, t.offer(c, nowMs = 300))
    assertEquals(c, t.pending)
    // The gap ends: the newest card goes.
    assertEquals(c, t.takePending(nowMs = 500))
    t.sent(c, nowMs = 500)
    assertNull(t.pending)
    // A change after the gap goes at once.
    assertEquals(CardDecision.Send, t.offer(a, nowMs = 1_100))
  }

  @Test
  fun aChangeBackToWhatIsShownCancelsThePendingSend() {
    val t = CardThrottle(minGapMs = 500)
    val a = GlassesCard(screen = "Main menu")
    val b = GlassesCard(screen = "Mail reader")
    t.sent(a, nowMs = 0)
    assertEquals(CardDecision.Later(400), t.offer(b, nowMs = 100))
    assertEquals(CardDecision.Unchanged, t.offer(a, nowMs = 200))
    assertNull(t.takePending(nowMs = 500))
  }

  @Test
  fun afterAResetTheSameCardIsSentAgain() {
    val t = CardThrottle(minGapMs = 500)
    val a = GlassesCard(screen = "Main menu")
    t.sent(a, nowMs = 0)
    t.reset()
    assertEquals(CardDecision.Send, t.offer(a, nowMs = 10))
  }
}
