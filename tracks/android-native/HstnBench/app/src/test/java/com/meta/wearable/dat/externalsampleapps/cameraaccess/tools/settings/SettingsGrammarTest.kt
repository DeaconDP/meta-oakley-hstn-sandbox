package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings

import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.VoiceCommands
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.GlobalGrammar
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.Phrases
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.labels.LabelsGrammar
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.light.LightGrammar
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.mail.MailGrammar
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.SettingsCommand as C
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.watch.WatchGrammar
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SettingsGrammarTest {

  private val ctx = SettingsContext(profiles = listOf("home", "out and about", "reading"))

  private fun p(s: String, c: SettingsContext = ctx) = SettingsGrammar.parse(s, c)

  private val EXAMPLES: Map<String, C> =
      linkedMapOf(
          "Keep that" to C.Keep,
          "keep it please" to C.Keep,
          "make that the default" to C.Keep,
          "undo" to C.Undo,
          "put it back" to C.Undo,
          "What's my setup?" to C.WhatsMySetup,
          "what have I changed" to C.WhatsMySetup,
          "reset speech" to C.Reset(Area.SPEECH),
          "reset the sounds" to C.Reset(Area.SOUNDS),
          "reset my shortcuts" to C.Reset(Area.WORDS),
          "reset everything" to C.Reset(null),
          "lock settings" to C.Lock,
          "unlock my settings" to C.Unlock,
          "shorter" to C.Shorter(),
          "less detail" to C.Shorter(),
          "more detail" to C.MoreDetail(),
          "make mail shorter" to C.Shorter("mail"),
          "keep the book detailed" to C.MoreDetail("book"),
          "brisk speech" to C.UsePreset(Preset.BRISK),
          "be gentle" to C.UsePreset(Preset.GENTLE),
          "normal speech" to C.UsePreset(Preset.NORMAL),
          "clear speech" to C.ClearSpeech(true),
          "turn off clear speech" to C.ClearSpeech(false),
          "higher pitch" to C.Pitch(0.1f),
          "deeper voice" to C.Pitch(-0.1f),
          "longer pauses" to C.Pauses(150),
          "no pauses" to C.Pauses(null),
          "try another voice" to C.TryVoice,
          "what voices are there" to C.ListVoices,
          "default voice" to C.DefaultVoice,
          "turn off the beeps" to C.Earcons(false),
          "sounds on" to C.Earcons(true),
          "louder beeps" to C.EarconVolume(0.1f),
          "only the beeps" to C.EarconsOnly(true),
          "beeps only" to C.EarconsOnly(true),
          "words again" to C.EarconsOnly(false),
          "tell me what the sounds mean" to C.SpeakEarcons(true),
          "move it left a bit" to C.Balance(-0.1f),
          "move it right a bit" to C.Balance(0.1f),
          "move it to the right" to C.Balance(0.2f),
          "more in my left ear" to C.Balance(-0.2f),
          "centre the sound" to C.Balance(null),
          "speech in my left ear" to C.Route("speech", Ear.LEFT),
          "beeps in my right ear" to C.Route("earcons", Ear.RIGHT),
          "everything in both ears" to C.Route("all", Ear.BOTH),
          "I use mono" to C.Mono(true),
          "I use stereo" to C.Mono(false),
          "someone's talking to me" to C.ConversationStart,
          "forget the shortcut post" to C.ForgetShortcut("post"),
          "what are my shortcuts" to C.ListShortcuts,
          "put labels first" to C.MenuFirst("labels"),
          "move mail to the end" to C.MenuLast("mail"),
          "hide light and colour" to C.MenuHide(listOf("light")),
          "hide watch and labels from the menu" to C.MenuHide(listOf("watch", "labels")),
          "show light on the menu" to C.MenuShow(listOf("light")),
          "what's on my menu" to C.WhatsOnMenu,
          "call yourself Sam" to C.Address("sam"),
          "fewer tips" to C.TipPacing(Pacing.FEWER),
          "no more tips" to C.TipPacing(Pacing.OFF),
          "switch to out and about" to C.SwitchProfile("out and about"),
          "use the reading profile" to C.SwitchProfile("reading"),
          "home profile" to C.SwitchProfile("home"),
          "save this as kitchen" to C.SaveProfile("kitchen"),
          "which profile am I on" to C.WhichProfile,
          "what do my buttons do" to C.WhatDoMyButtons,
          "turn on glasses controls" to C.ControlsOn(true),
          "when I hold the capture button, read my mail" to C.MapButton("captureHold", "read my mail"),
          "share my setup" to C.ShareSetup,
          "open settings" to C.OpenSettings,
          "same speed everywhere" to C.SameSpeedEverywhere,
      )

  @Test
  fun everySettingsPhraseParses() {
    for ((said, expected) in EXAMPLES) assertEquals(said, expected, p(said))
  }

  @Test
  fun shortcutsKeepTheCommaWhenHeard() {
    assertEquals(C.DefineShortcut("post", "open the mail reader", "post open the mail reader"), p("When I say post, open the mail reader."))
    assertEquals(C.DefineShortcut(null, null, "morning post open mail and read it all"), p("when I say morning post open mail and read it all"))
    assertEquals(C.DefineShortcut("post", "open the mail reader", "post open the mail reader"), p("Glasses, when I say \"post\": open the mail reader"))
  }

  @Test
  fun contextWordsOnlyCountInContext() {
    assertNull(p("go back"))
    assertNull(p("this one"))
    assertNull(p("yes"))
    val trial = ctx.copy(tryingVoices = true)
    assertEquals(C.PreviousVoice, p("go back", trial))
    assertEquals(C.KeepVoice, p("keep this one", trial))
    assertEquals(C.TryVoice, p("next", trial))
    assertEquals(C.CancelVoice, p("never mind", trial))
    assertEquals(C.Yes, p("yes please", ctx.copy(question = true)))
    assertEquals(C.No, p("no thanks", ctx.copy(question = true)))
    // Conversation mode hears only the way out.
    val talk = ctx.copy(conversation = true)
    assertEquals(C.ConversationEnd, p("carry on", talk))
    assertEquals(C.ConversationEnd, p("I'm back", talk))
    assertNull(p("stop", talk))
    assertNull(p("read my mail", talk))
    assertNull(p("faster", talk))
  }

  @Test
  fun profilesOnlyMatchKnownNamesAndNotTheBook() {
    assertNull(p("switch to the kitchen"))
    assertNull(p("start reading"))
    assertNull(p("go to reading"))
    assertEquals(C.SwitchProfile("kitchen"), p("switch to kitchen", ctx.copy(profiles = listOf("kitchen"))))
  }

  @Test
  fun roomChatterIsNotASetting() {
    for (s in listOf("turn right at the lights", "I'll keep it for later", "my mail came late", "she said undo the knot", "", "the post office")) {
      assertNull(s, p(s))
    }
  }

  /** Settings words mustn't take phrases other grammars already use, so ordering never matters. */
  @Test
  fun settingsPhrasesDontClashWithOtherGrammars() {
    val clashes = mutableListOf<String>()
    for (said in EXAMPLES.keys) {
      val n = Phrases.normalize(said)
      val other =
          GlobalGrammar.parse(said) ?: VoiceCommands.parse(said) ?: MailGrammar.parse(n) ?: WatchGrammar.parse(n, Phrases.light(said))
              ?: LabelsGrammar.parse(n) ?: LightGrammar.parse(n)
      if (other != null) clashes += "$said -> $other"
    }
    assertTrue(clashes.joinToString("\n"), clashes.isEmpty())
  }

  @Test
  fun theGlobalSpeedPhrasesStayGlobal() {
    for (s in listOf("faster", "a bit slower", "1.5 times", "normal speed", "reset the speed")) assertNull(s, p(s))
  }
}
