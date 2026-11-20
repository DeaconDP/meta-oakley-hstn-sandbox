package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ShortcutsAndVoiceTest {

  private fun define(said: String, words: Words = Words()): Shortcuts.Result =
      Shortcuts.define(SettingsGrammar.parse(said) as SettingsCommand.DefineShortcut, words)

  @Test
  fun anAliasIsAddedAndRewrites() {
    val r = define("When I say post, open the mail reader")
    assertTrue(r.toString(), r is Shortcuts.Result.Added)
    val w = (r as Shortcuts.Result.Added).words
    assertEquals("open the mail reader", w.aliases["post"])
    assertEquals("When you say post, I'll open the mail reader.", r.spoken)
    assertEquals(Shortcuts.Rewrite.Alias("post", "open the mail reader"), Shortcuts.rewrite("Post.", w))
    assertNull(Shortcuts.rewrite("post it to me", w))
  }

  @Test
  fun withoutACommaTheSplitThatMakesSenseIsUsed() {
    val r = define("when I say post open the mail reader") as Shortcuts.Result.Added
    assertEquals("open the mail reader", r.words.aliases["post"])
  }

  @Test
  fun aRoutineIsBuiltAndReadBack() {
    val r = define("when I say morning post, read my mail and then read it all")
    assertTrue(r.toString(), r is Shortcuts.Result.Added)
    r as Shortcuts.Result.Added
    assertEquals(listOf("read my mail", "read it all"), r.words.macros["morning post"])
    assertEquals("When you say morning post, I'll read my mail, then read it all.", r.spoken)
    assertEquals(Shortcuts.Rewrite.Macro("morning post", listOf("read my mail", "read it all")), Shortcuts.rewrite("morning post", r.words))
  }

  @Test
  fun conflictsAreRefusedWithAReason() {
    val r = define("when I say stop, open the mail reader")
    assertTrue(r is Shortcuts.Result.Refused)
    assertTrue((r as Shortcuts.Result.Refused).spoken, r.spoken.startsWith("stop already means"))
    val bad = define("when I say zebra, do a little dance") as Shortcuts.Result.Refused
    assertTrue(bad.spoken, bad.spoken.startsWith("I don't know how to"))
    // No shortcut to a shortcut.
    val w = (define("when I say post, open the mail reader") as Shortcuts.Result.Added).words
    assertTrue(define("when I say letters please, post", w) is Shortcuts.Result.Refused)
  }

  @Test
  fun forgetAndList() {
    val w = (define("when I say post, open the mail reader") as Shortcuts.Result.Added).words
    assertEquals("Your shortcuts. post: open the mail reader.", Shortcuts.listLine(w))
    val f = Shortcuts.forget("post", w) as Shortcuts.Result.Added
    assertTrue(f.words.aliases.isEmpty())
    assertTrue(Shortcuts.forget("post", f.words) is Shortcuts.Result.Refused)
  }

  // MARK: SettingsVoice

  private class Env : SettingsEnv {
    override fun voices() = listOf(VoiceChoice("a", "voice A"), VoiceChoice("b", "voice B"), VoiceChoice("c", "voice C"))

    override fun languageName() = "English"
  }

  private fun voice() = SettingsVoice(SettingsStore(MemoryStorage()), Env())

  private fun SettingsVoice.say(s: String, tool: String? = null) = handle(parse(s) ?: error("not a setting: $s"), tool).text

  @Test
  fun everyChangeSpeaksItsNewValueAndTheFirstHintsKeepThat() {
    val v = voice()
    assertEquals("1.3 times speed. Say keep that to keep it.", v.changeRate(null) { it + 0.25f }.text)
    assertEquals("1.5 times speed.", v.changeRate(null) { 1.5f }.text)
    assertEquals("That's the fastest.", v.changeRate(null) { 3f }.let { v.changeRate(null) { it + 0.25f } }.text)
    assertEquals("Short replies.", v.say("shorter"))
    assertEquals("That's already the shortest.", v.say("shorter"))
    assertEquals("Mail: normal replies.", v.say("make mail more detailed"))
    assertEquals("Mail: detailed replies.", v.say("make mail more detailed"))
    assertEquals("Balance 10 percent to the left.", v.say("move it left a bit"))
    assertEquals("Speech in your left ear.", v.say("speech in my left ear"))
    assertTrue(v.say("what's my setup"), v.say("what's my setup").contains("Not kept yet: speech and ears"))
  }

  @Test
  fun theBookChangesItsOwnSpeedOnlyIfItHasOne() {
    val v = voice()
    v.changeRate("book") { it + 0.5f }
    assertEquals(1.5f, v.store.current.speech.rate)
    v.store.change("book override", keep = true) { it.copy(speech = it.speech.withTool("book") { t -> t.copy(rate = 1.2f) }) }
    v.changeRate("book") { it - 0.2f }
    assertEquals(1f, v.store.current.rateFor("book"))
    assertEquals(1.5f, v.store.current.speech.rate)
    v.say("same speed everywhere")
    assertEquals(1.5f, v.store.current.rateFor("book"))
  }

  @Test
  fun tryingVoicesGoesForwardBackAndKeeps() {
    val v = voice()
    assertTrue(v.say("try another voice").startsWith("Voice 1 of 3, voice A."))
    assertTrue(v.tryingVoices)
    assertTrue(v.say("next").startsWith("Voice 2 of 3"))
    assertEquals("b", v.store.current.speech.voice)
    assertTrue(v.say("go back").startsWith("Voice 1 of 3"))
    assertEquals("Keeping this voice.", v.say("keep this one"))
    assertFalse(v.tryingVoices)
    assertEquals("a", v.store.saved.speech.voice)
    v.say("try another voice")
    v.say("never mind")
    assertEquals("a", v.store.current.speech.voice)
  }

  @Test
  fun lockedSettingsSaySo() {
    val v = voice()
    v.say("lock settings")
    assertEquals("Settings are locked. Say unlock settings first.", v.say("longer pauses"))
    assertEquals("Settings are locked. Say unlock settings first.", v.changeRate(null) { it + 1f }.text)
    assertEquals("Settings unlocked.", v.say("unlock settings"))
  }

  @Test
  fun aLearnedSuggestionWaitsForYes() {
    val v = voice()
    v.changeRate(null) { it - 0.1f }
    v.changeRate(null) { it - 0.1f }
    val third = v.changeRate(null) { it - 0.1f }.text
    assertTrue(third, third.contains("You've said slower 3 times. Make this your default for home? Say yes or no."))
    assertTrue(v.context.question)
    assertTrue(v.store.hasUnkept)
    assertTrue(v.say("yes").startsWith("Kept."))
    assertFalse(v.store.hasUnkept)
  }

  @Test
  fun shortcutsMenuAndButtonsBySpeech() {
    val v = voice()
    assertEquals("When you say post, I'll open the mail reader.", v.say("when I say post, open the mail reader"))
    assertFalse(v.store.hasUnkept) // saved straight away
    assertEquals("The book hidden. The book still opens if you ask for it.", v.say("hide the book"))
    assertEquals("Your menu: mail, labels, watch for text and light.", v.say("what's on my menu"))
    assertEquals("I'll keep at least one tool on the menu.", v.say("hide mail, labels, watch and light"))
    assertTrue(v.say("what do my buttons do").contains("A short press of the capture button: say that again"))
    assertEquals("Holding the capture button will now: post.", v.say("when I hold the capture button, post"))
    assertEquals(SettingsVoice.Effect.CONVERSATION_START, v.handle(SettingsCommand.ConversationStart).effect)
    assertTrue(v.conversation)
    assertNull(v.parse("read my mail"))
    assertEquals(SettingsCommand.ConversationEnd, v.parse("carry on"))
    assertEquals(SettingsVoice.Effect.CONVERSATION_END, v.handle(SettingsCommand.ConversationEnd).effect)
    assertFalse(v.conversation)
  }

  @Test
  fun panAndBalanceMaths() {
    val centre = Ears()
    assertEquals(AudioMath.Gains(1f, 1f), AudioMath.gains(AudioMath.Kind.SPEECH, centre))
    assertEquals(AudioMath.Gains(1f, 0f), AudioMath.gains(AudioMath.Kind.SPEECH, Ears(speech = Ear.LEFT)))
    assertEquals(AudioMath.Gains(0f, 1f), AudioMath.gains(AudioMath.Kind.EARCON, Ears(earcons = Ear.RIGHT)))
    val b = AudioMath.gains(AudioMath.Kind.SPEECH, Ears(balance = -0.25f))
    assertEquals(1f, b.left, 1e-6f)
    assertEquals(0.75f, b.right, 1e-6f)
    // Cues follow the thing seen, then balance; mono flattens everything.
    assertEquals(AudioMath.Gains(0.5f, 1f), AudioMath.gains(AudioMath.Kind.CUE, centre, cue = 0.5f))
    assertEquals(AudioMath.Gains(1f, 1f), AudioMath.gains(AudioMath.Kind.CUE, Ears(mono = true, balance = 0.8f), cue = -1f))
    assertEquals(0f, AudioMath.pan(AudioMath.Kind.SPEECH, Ears(mono = true, speech = Ear.LEFT)))
    assertEquals(1f, AudioMath.pan(AudioMath.Kind.SPEECH, Ears(speech = Ear.RIGHT, balance = 0.5f)))
    assertEquals(440f, AudioMath.cueFrequency(-1f))
    assertEquals(660f, AudioMath.cueFrequency(0f))
    assertEquals(880f, AudioMath.cueFrequency(0.9f))
  }

  @Test
  fun mixingAndEarconSounds() {
    val dst = FloatArray(8)
    AudioMath.mixInto(dst, 1, shortArrayOf(Short.MAX_VALUE, 0, Short.MIN_VALUE), 0, 3, AudioMath.Gains(1f, 0.5f))
    assertEquals(0f, dst[0])
    assertEquals(1f, dst[2], 1e-4f)
    assertEquals(0.5f, dst[3], 1e-4f)
    assertEquals(-1f, dst[6], 1e-3f)
    val pcm = ShortArray(8)
    AudioMath.toPcm16(floatArrayOf(2f, -2f, 0.5f), pcm, 3)
    assertEquals(Short.MAX_VALUE, pcm[0])
    assertEquals((-Short.MAX_VALUE).toShort(), pcm[1])
    // Every earcon has a pannable version within the 100 ms rule's spirit: short and immediate.
    for ((name, notes) in AudioMath.EARCON_NOTES) {
      val ms = notes.sumOf { it.second }
      assertTrue("$name is $ms ms", ms in 20..260)
      val samples = AudioMath.tones(notes, 22_050)
      assertEquals(name, notes.sumOf { (22_050 * it.second / 1000).coerceAtLeast(16) }, samples.size)
      assertEquals("$name starts silent (fade in)", 0, samples[0].toInt())
    }
    val stereo = AudioMath.toStereo(shortArrayOf(1000), AudioMath.Gains(1f, 0f))
    assertEquals(listOf<Short>(1000, 0), stereo.toList())
    // Mixer latency budget at 24 kHz: 5 ms blocks + a 20 ms track buffer.
    assertEquals(25f, AudioMath.busLatencyMs(120, 480, 24_000), 0.01f)
  }
}
