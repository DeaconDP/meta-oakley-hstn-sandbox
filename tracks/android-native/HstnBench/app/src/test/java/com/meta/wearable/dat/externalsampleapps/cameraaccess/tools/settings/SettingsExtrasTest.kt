package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class SettingsExtrasTest {

  @Test
  fun shortRepliesKeepTheFirstSentence() {
    assertEquals("Mail reader ready.", SetupSpeech.firstSentence("Mail reader ready. Hold a letter up and say what is this letter."))
    assertEquals("Read at 1.5 times.", SetupSpeech.firstSentence("Read at 1.5 times. Then stop."))
    assertEquals("No full stop", SetupSpeech.firstSentence("No full stop"))
  }

  @Test
  fun oneChangeMakesATinyCode() {
    val s = SettingsStore(MemoryStorage())
    s.change("faster", keep = true) { it.copy(speech = it.speech.copy(rate = 1.5f)) }
    val code = s.exportCode()
    assertTrue(code, code.length < 120)
    val json = SetupJson.fromCode(code)!!
    assertTrue(json, json.contains("\"speech\":{\"rate\":1.5}"))
    assertFalse("unchanged starter profiles are left out: $json", json.contains("reading"))
    // And it imports on a fresh phone with the starters still there.
    val other = SettingsStore(MemoryStorage())
    other.import(code)
    assertEquals(1.5f, other.current.speech.rate)
    assertTrue(other.hasProfile("reading"))
  }

  @Test
  fun ttsAudioIsDecodedAndResampled() {
    val pcm = AudioMath.pcm16le(byteArrayOf(0x01, 0x00, 0xFF.toByte(), 0x7F, 0x00, 0x80.toByte()))
    assertEquals(listOf<Short>(1, Short.MAX_VALUE, Short.MIN_VALUE), pcm.toList())
    val stereo = AudioMath.pcm16le(byteArrayOf(5, 0, 9, 9, 6, 0, 9, 9), channels = 2)
    assertEquals(listOf<Short>(5, 6), stereo.toList())
    val up = AudioMath.resample(shortArrayOf(0, 100, 200, 300), 16_000, 24_000)
    assertEquals(6, up.size)
    assertEquals(0, up[0].toInt())
    assertTrue(up.toList().zipWithNext().all { (a, b) -> b >= a })
    assertSame(pcm, AudioMath.resample(pcm, 24_000, 24_000))
  }

  @Test
  fun theCatalogKnowsWhatPhrasesMean() {
    assertNull(CommandCatalog.meaningOf("post"))
    assertNull(CommandCatalog.meaningOf("morning post"))
    assertNotNull(CommandCatalog.meaningOf("faster"))
    assertNotNull(CommandCatalog.meaningOf("read it all"))
    assertNotNull(CommandCatalog.meaningOf("keep that"))
    assertTrue(CommandCatalog.understands("book"))
  }

  @Test
  fun tipPacingSetsTheReminderGaps() {
    assertEquals(3, Tips(Pacing.NORMAL).reminderGapsMs().size)
    assertEquals(listOf(60_000L, 180_000L), Tips(Pacing.FEWER).reminderGapsMs())
    assertTrue(Tips(Pacing.OFF).reminderGapsMs().isEmpty())
  }

  @Test
  fun theMenuKeepsEveryToolOnceAndHidesOnRequest() {
    val w = Words(menuOrder = listOf("labels", "nonsense", "labels"), menuHidden = listOf("light"))
    assertEquals(listOf("labels", "book", "mail", "watch", "light"), w.normalisedOrder())
    assertEquals(listOf("labels", "book", "mail", "watch"), w.visibleMenu())
  }
}
