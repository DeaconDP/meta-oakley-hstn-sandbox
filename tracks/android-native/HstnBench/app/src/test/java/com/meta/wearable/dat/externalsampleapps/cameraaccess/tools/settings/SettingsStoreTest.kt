package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings

import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.SettingsStore.Outcome
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SettingsStoreTest {

  private fun store(storage: MemoryStorage = MemoryStorage(), old: OldPrefs? = null) = SettingsStore(storage) { old }

  private fun faster(s: Setup) = s.copy(speech = s.speech.copy(rate = Speech.clampRate(s.speech.rate + 0.25f)))

  @Test
  fun migratesTheOldPrefsWithoutLosingValues() {
    val storage = MemoryStorage()
    val s = store(storage, OldPrefs(toolsRate = 1.5f, bookRate = 1.2f, pageNumbers = true, autoTurn = false, watchTickSeconds = 20))
    assertTrue(s.migrated)
    assertEquals(1.5f, s.current.speech.rate)
    assertEquals(1.2f, s.current.rateFor("book"))
    assertEquals(1.5f, s.current.rateFor("mail"))
    assertTrue(s.current.bookPageNumbers)
    assertFalse(s.current.bookAutoTurn)
    assertEquals(20, s.current.sounds.watchTickSeconds)
    // Written straight away, and read back the same by a new store (no second migration).
    val again = SettingsStore(storage) { error("old prefs read twice") }
    assertEquals(s.current, again.current)
  }

  @Test
  fun aBookRateEqualToTheMainRateIsNotAnOverride() {
    val s = store(old = OldPrefs(toolsRate = 1.3f, bookRate = 1.3f))
    assertTrue(s.current.speech.tools.isEmpty())
    val onlyBook = store(old = OldPrefs(bookRate = 1.8f))
    assertEquals(1f, onlyBook.current.speech.rate)
    assertEquals(1.8f, onlyBook.current.rateFor("book"))
  }

  @Test
  fun noOldPrefsMeansDefaults() {
    val s = store()
    assertEquals(Setup(), s.current)
    assertEquals(listOf("home", "out and about", "reading"), s.profiles.keys.toList())
  }

  @Test
  fun voiceTweaksLastTheSessionUntilKept() {
    val storage = MemoryStorage()
    val s = store(storage)
    s.change("faster") { faster(it) }
    assertEquals(1.3f, s.current.speech.rate)
    assertTrue(s.hasUnkept)
    assertEquals(listOf(Area.SPEECH), s.unkeptAreas())
    // A restart forgets it.
    assertEquals(1f, SettingsStore(storage).current.speech.rate)
    val kept = s.keep()
    assertTrue(kept is Outcome.Changed)
    assertTrue((kept as Outcome.Changed).spoken, kept.spoken.contains("1.3 times"))
    assertFalse(s.hasUnkept)
    assertEquals(1.3f, SettingsStore(storage).current.speech.rate)
    assertEquals(Outcome.Unchanged("Nothing new to keep."), s.keep())
  }

  @Test
  fun undoPutsBackTheLastChangeIncludingKeptOnes() {
    val storage = MemoryStorage()
    val s = store(storage)
    s.change("faster") { faster(it) }
    s.keep()
    s.change("sounds off", keep = true) { it.copy(sounds = it.sounds.copy(earcons = false)) }
    assertFalse(SettingsStore(storage).current.sounds.earcons)
    assertEquals(Outcome.Changed("Put back: sounds off."), s.undo())
    assertTrue(s.current.sounds.earcons)
    assertTrue(SettingsStore(storage).current.sounds.earcons)
    s.undo() // the keep
    assertEquals(1f, SettingsStore(storage).current.speech.rate)
    assertEquals(1.3f, s.current.speech.rate) // back to unkept
    s.undo()
    assertEquals(1f, s.current.speech.rate)
    assertEquals(Outcome.Unchanged("Nothing to undo."), s.undo())
  }

  @Test
  fun resetIsPerAreaAndCanBeUndone() {
    val s = store()
    s.change("x", keep = true) { faster(it).copy(sounds = it.sounds.copy(volume = 0.4f)) }
    s.reset(Area.SPEECH)
    assertEquals(1f, s.current.speech.rate)
    assertEquals(0.4f, s.current.sounds.volume)
    s.undo()
    assertEquals(1.3f, s.current.speech.rate)
    s.resetAll()
    assertEquals(Setup(), s.current)
    s.undo()
    assertEquals(0.4f, s.current.sounds.volume)
  }

  @Test
  fun lockStopsEveryChangeUntilUnlocked() {
    val storage = MemoryStorage()
    val s = store(storage)
    s.lock()
    assertEquals(Outcome.Locked, s.change("faster") { faster(it) })
    assertEquals(Outcome.Locked, s.undo())
    assertEquals(Outcome.Locked, s.reset(Area.SPEECH))
    assertEquals(Outcome.Locked, s.switchProfile("reading"))
    assertEquals(Outcome.Locked, s.import(s.exportJson()))
    assertTrue(SettingsStore(storage).locked) // survives a restart
    s.unlock()
    assertTrue(s.change("faster") { faster(it) } is Outcome.Changed)
  }

  @Test
  fun profilesSwitchSaveAndKeepWordsEverywhere() {
    val s = store()
    s.change("alias", keep = true) { it.copy(words = it.words.copy(aliases = mapOf("post" to "open the mail reader"))) }
    val r = s.switchProfile("out and about")
    assertTrue(r.toString(), r is Outcome.Changed)
    assertEquals("out and about", s.activeProfile)
    assertEquals(Preset.BRISK, s.current.speech.preset)
    assertTrue(s.current.sounds.earconsOnly)
    assertEquals("open the mail reader", s.current.words.aliases["post"])
    // A kept tweak goes into the active profile.
    s.change("slower") { it.copy(speech = it.speech.copy(rate = 1.2f)) }
    s.keep()
    s.switchProfile("home")
    assertEquals(1f, s.current.speech.rate)
    s.switchProfile("out and about")
    assertEquals(1.2f, s.current.speech.rate)
    // Save as a new one; undo goes back.
    s.change("pitch") { it.copy(speech = it.speech.copy(pitch = 1.2f)) }
    s.saveProfile("Kitchen")
    assertEquals("kitchen", s.activeProfile)
    assertEquals(1.2f, s.setupFor("kitchen").speech.pitch)
    s.undo()
    assertEquals("out and about", s.activeProfile)
    assertFalse(s.hasProfile("kitchen"))
    assertTrue(s.switchProfile("nowhere") is Outcome.Unchanged)
  }

  @Test
  fun aLearnedSuggestionIsAskedAfterThreeTweaksAndNeverApplied() {
    val s = store()
    assertNull(s.change("x") { faster(it) }.let { s.noteTweak("faster") })
    assertNull(s.noteTweak("faster"))
    val q = s.noteTweak("faster")
    assertNotNull(q)
    assertTrue(q!!, q.contains("3 times") && q.contains("home"))
    assertTrue(s.hasUnkept) // asked, not applied
    assertEquals("faster", s.pendingSuggestion)
    s.answerSuggestion(true)
    assertFalse(s.hasUnkept)
    // Declining stops the question for that kind.
    s.change("y") { faster(it) }
    repeat(3) { s.noteTweak("slower") }
    s.answerSuggestion(false)
    repeat(5) { assertNull(s.noteTweak("slower")) }
  }

  @Test
  fun exportImportRoundTripByJsonAndCode() {
    val a = store()
    a.change("setup", keep = true) {
      it.copy(
          speech = it.speech.copy(rate = 1.7f, pitch = 0.9f, voice = "en-gb-x-gbd-local", verbosity = Verbosity.SHORT).withTool("book") { t -> t.copy(rate = 1.1f, pageNumbers = true) },
          ears = it.ears.copy(balance = -0.3f, speech = Ear.LEFT, mono = true),
          words = it.words.copy(aliases = mapOf("post" to "open the mail reader"), macros = mapOf("morning post" to listOf("read my mail", "read it all")), menuHidden = listOf("light")),
          tips = Tips(Pacing.FEWER),
      )
    }
    a.saveProfile("walk")
    val json = a.exportJson()
    assertTrue(json, json.startsWith("{\"schema\":1,\"areas\":{\"speech\":{"))
    assertFalse("device fields aren't exported", json.contains("device"))
    val b = store()
    assertTrue(b.import(json) is Outcome.Changed)
    assertEquals(a.current, b.current)
    assertEquals(a.profiles, b.profiles)
    assertEquals("walk", b.activeProfile)

    val code = a.exportCode()
    assertTrue(code, code.startsWith("SU1.") && code.length < 400)
    val c = store()
    assertTrue(c.import("  $code\n") is Outcome.Changed)
    assertEquals(a.current, c.current)
    c.undo()
    assertEquals(Setup(), c.current)
  }

  @Test
  fun importIsTolerantAndRefusesWhatItCantUse() {
    val s = store()
    assertTrue(s.import("hello") is Outcome.Unchanged)
    assertTrue(s.import("SU1.!!!") is Outcome.Unchanged)
    assertTrue(s.import("{\"schema\":2,\"areas\":{}}") is Outcome.Unchanged)
    // Unknown areas and fields (including anything that tries to switch off safety rules) are ignored.
    val r = s.import("{\"schema\":1,\"areas\":{\"speech\":{\"rate\":9,\"skipRefusals\":true},\"safety\":{\"faceBlur\":false}}}")
    assertTrue(r is Outcome.Changed)
    assertEquals(3f, s.current.speech.rate)
    assertFalse(s.exportJson().contains("skipRefusals"))
    assertFalse(s.exportJson().contains("faceBlur"))
    // A bare areas object (what iOS might paste) works too.
    s.import("{\"sounds\":{\"earcons\":false}}")
    assertFalse(s.current.sounds.earcons)
  }

  @Test
  fun theJsonSchemaFieldsAreStable() {
    val m = Setup().areasMap()
    assertEquals(listOf("speech", "sounds", "ears", "words", "controls", "tips", "descriptions"), m.keys.toList())
    assertEquals(listOf("preset", "rate", "pitch", "pauseMs", "verbosity", "voice", "locale", "tools"), (m["speech"] as Map<*, *>).keys.toList())
    assertEquals(listOf("earcons", "volume", "earconsOnly", "speakEarcons", "watchTickSeconds"), (m["sounds"] as Map<*, *>).keys.toList())
    assertEquals(listOf("balance", "speech", "earcons", "cues", "mono", "clearSpeech"), (m["ears"] as Map<*, *>).keys.toList())
    assertEquals(listOf("aliases", "macros", "menuOrder", "menuHidden", "address"), (m["words"] as Map<*, *>).keys.toList())
    assertEquals(listOf("enabled") + Controls.EVENTS, (m["controls"] as Map<*, *>).keys.toList())
    assertEquals(listOf("pacing"), (m["tips"] as Map<*, *>).keys.toList())
    assertEquals(listOf("detail", "textFirst", "colours", "directions"), (m["descriptions"] as Map<*, *>).keys.toList())
    assertEquals("{\"preset\":\"normal\",\"rate\":1.0,\"pitch\":1.0,\"pauseMs\":0,\"verbosity\":\"normal\",\"voice\":null,\"locale\":null,\"tools\":{}}", SetupJson.encode(m["speech"]))
  }

  @Test
  fun whatsMySetupSpeaksOnlyDifferences() {
    assertTrue(SetupSpeech.differences(Setup()).isEmpty())
    val s = Setup(speech = Speech(preset = Preset.BRISK, rate = 1.6f, verbosity = Verbosity.SHORT), sounds = Sounds(volume = 0.5f), ears = Ears(balance = -0.2f))
    assertEquals(listOf("Brisk speech", "but speed 1.6 times", "sounds at 50 percent", "balance 20 percent to the left"), SetupSpeech.differences(s))
  }

  @Test
  fun clearSpeechCapsTheRate() {
    val s = Setup(speech = Speech(rate = 2f), ears = Ears(clearSpeech = true))
    assertEquals(1f, s.rateFor(null))
    assertEquals(2f, s.copy(ears = Ears()).rateFor("mail"))
  }
}
