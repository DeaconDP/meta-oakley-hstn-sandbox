// SettingsVoice - what happens when a settings command is heard, and what is said back
//
// Turns a SettingsCommand into a store change and a spoken reply with the new value. Voice tweaks
// are for this session until "keep that" (the first one says so, once); shortcuts, menu, controls,
// resets and profiles are saved at once and can be undone. After the third tweak of the same kind
// it asks whether to make it the default, and does nothing without a yes.
//
// The few things that need Android (the installed voices, the share sheet, the settings screen,
// conversation mode in ToolHub) come through [SettingsEnv] and [Reply.effect]. Pure Kotlin,
// JVM-tested.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings

import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.SettingsStore.Outcome

/** An installed TTS voice: [name] is stored, [label] is spoken ("British English, voice 3"). */
data class VoiceChoice(val name: String, val label: String)

interface SettingsEnv {
  /** Installed voices for the speech language, best first. */
  fun voices(): List<VoiceChoice> = emptyList()

  /** The speech language as words ("English (United Kingdom)"). */
  fun languageName(): String = "this language"

  /** The glasses controls can be wired (the Inputs capability is in this build). */
  val controlsAvailable: Boolean
    get() = false
}

class SettingsVoice(val store: SettingsStore, private val env: SettingsEnv = object : SettingsEnv {}) {

  enum class Effect { CONVERSATION_START, CONVERSATION_END, SHARE_SETUP, OPEN_SETTINGS }

  data class Reply(val text: String, val effect: Effect? = null)

  /** Conversation mode: earcons only, listening only for "carry on". ToolHub reads this. */
  var conversation = false
    private set

  var tryingVoices = false
    private set

  private var voiceBefore: String? = null
  private var voiceIndex = -1
  private var hintedKeep = false

  val context: SettingsContext
    get() = SettingsContext(tryingVoices, store.pendingSuggestion != null, conversation, store.profiles.keys)

  fun parse(transcript: String): SettingsCommand? = SettingsGrammar.parse(transcript, context)

  /** A settings command, said while [tool] (a ToolId.id, null for the home menu) is open. */
  fun handle(cmd: SettingsCommand, tool: String? = null): Reply {
    if (cmd != SettingsCommand.Yes && cmd != SettingsCommand.No) store.dropSuggestion()
    if (tryingVoices && cmd !in VOICE_TRIAL_COMMANDS) tryingVoices = false
    return when (cmd) {
      SettingsCommand.Keep -> outcome(store.keep())
      SettingsCommand.Undo -> outcome(store.undo())
      SettingsCommand.WhatsMySetup -> Reply(whatsMySetup())
      is SettingsCommand.Reset -> outcome(if (cmd.area == null) store.resetAll() else store.reset(cmd.area), suffix = " Say undo to put it back.")
      SettingsCommand.Lock -> outcome(store.lock())
      SettingsCommand.Unlock -> outcome(store.unlock())

      is SettingsCommand.Shorter -> verbosity(cmd.tool, tool, "shorter") { it.shorter() }
      is SettingsCommand.MoreDetail -> verbosity(cmd.tool, tool, "more detail") { it.longer() }
      is SettingsCommand.SetVerbosity -> verbosity(cmd.tool, tool, "normal detail") { cmd.verbosity }
      is SettingsCommand.UsePreset -> {
        val p = cmd.preset
        tweak("${p.id} speech", "${p.spoken} speech: ${SetupSpeech.rate(p.rate)}, ${p.verbosity.spoken} replies") {
          it.copy(speech = it.speech.copy(preset = p, rate = p.rate, pitch = p.pitch, pauseMs = p.pauseMs, verbosity = p.verbosity))
        }
      }
      is SettingsCommand.ClearSpeech ->
          tweak(
              null,
              if (cmd.on) "Clear speech on. I'll speak a little slower, louder and crisper" else "Clear speech off",
          ) { it.copy(ears = it.ears.copy(clearSpeech = cmd.on)) }
      is SettingsCommand.Pitch -> {
        val p = cmd.step?.let { Speech.clampPitch(store.current.speech.pitch + it) } ?: 1f
        tweak(if ((cmd.step ?: 0f) > 0) "higher" else "lower", SetupSpeech.pitch(p)) { it.copy(speech = it.speech.copy(pitch = p)) }
      }
      is SettingsCommand.Pauses -> {
        val ms = cmd.step?.let { (store.current.speech.pauseMs + it).coerceIn(0, 1200) } ?: 0
        tweak(null, SetupSpeech.pauses(ms)) { it.copy(speech = it.speech.copy(pauseMs = ms)) }
      }
      SettingsCommand.SameSpeedEverywhere ->
          tweak(null, "Same speed everywhere: ${SetupSpeech.rate(store.current.speech.rate)}") { s ->
            s.copy(speech = s.speech.copy(tools = s.speech.tools.mapValues { it.value.copy(rate = null) }.filterValues { !it.isEmpty }))
          }

      SettingsCommand.TryVoice -> tryVoice(1)
      SettingsCommand.PreviousVoice -> tryVoice(-1)
      SettingsCommand.KeepVoice -> {
        tryingVoices = false
        when (val o = store.keep()) {
          Outcome.Locked -> locked()
          else -> Reply(if (o is Outcome.Changed) "Keeping this voice." else "This is the voice you have.")
        }
      }
      SettingsCommand.CancelVoice -> {
        tryingVoices = false
        val before = voiceBefore
        tweak(null, "Back to your old voice") { it.copy(speech = it.speech.copy(voice = before)) }
      }
      SettingsCommand.ListVoices -> {
        val n = env.voices().size
        Reply(
            when {
              n <= 1 -> "There's one voice for ${env.languageName()} on this phone. You can add more in the phone's text-to-speech settings."
              else -> "There are $n voices for ${env.languageName()}. Say try another voice to hear them one by one."
            },
        )
      }
      SettingsCommand.DefaultVoice -> tweak(null, "The default voice") { it.copy(speech = it.speech.copy(voice = null)) }

      is SettingsCommand.Earcons -> tweak(null, if (cmd.on) "Sounds on" else "Sounds off. I'll still speak every problem") { it.copy(sounds = it.sounds.copy(earcons = cmd.on)) }
      is SettingsCommand.EarconVolume -> {
        val v = round2((store.current.sounds.volume + cmd.step).coerceIn(0.1f, 1f))
        tweak(if (cmd.step > 0) "louder sounds" else "quieter sounds", "Sounds at ${SetupSpeech.percent(v)}") {
          it.copy(sounds = it.sounds.copy(volume = v, earcons = true))
        }
      }
      is SettingsCommand.EarconsOnly ->
          tweak(null, if (cmd.on) "Sounds instead of short replies like paused and main menu" else "Words again for short replies") {
            it.copy(sounds = it.sounds.copy(earconsOnly = cmd.on, earcons = it.sounds.earcons || cmd.on))
          }
      is SettingsCommand.SpeakEarcons ->
          tweak(null, if (cmd.on) "I'll say what the sounds mean instead of playing them" else "Sounds again instead of words") {
            it.copy(sounds = it.sounds.copy(speakEarcons = cmd.on))
          }

      is SettingsCommand.Balance -> {
        val b = cmd.step?.let { round2((store.current.ears.balance + it).coerceIn(-1f, 1f)) } ?: 0f
        val monoNote = if (store.current.ears.mono) ". Mono is on, so you won't hear a difference until you say I use stereo" else ""
        tweak(null, SetupSpeech.balance(b).replaceFirstChar { it.uppercase() } + monoNote) { it.copy(ears = it.ears.copy(balance = b)) }
      }
      is SettingsCommand.Route -> {
        val spoken =
            when (cmd.kind) {
              "speech" -> SetupSpeech.ear("speech", cmd.ear)
              "earcons" -> SetupSpeech.ear("sounds", cmd.ear)
              "cues" -> SetupSpeech.ear("direction cues", cmd.ear)
              else -> SetupSpeech.ear("everything", cmd.ear)
            }
        tweak(null, spoken.replaceFirstChar { it.uppercase() }) { s ->
          val e = s.ears
          s.copy(
              ears =
                  when (cmd.kind) {
                    "speech" -> e.copy(speech = cmd.ear)
                    "earcons" -> e.copy(earcons = cmd.ear)
                    "cues" -> e.copy(cues = cmd.ear)
                    else -> e.copy(speech = cmd.ear, earcons = cmd.ear, cues = cmd.ear)
                  },
          )
        }
      }
      is SettingsCommand.Mono ->
          tweak(
              null,
              if (cmd.on) "Mono on. Directions will be a low sound for left and a high one for right, and I'll still say the side"
              else "Stereo. Directions play on their side",
          ) { it.copy(ears = it.ears.copy(mono = cmd.on)) }
      SettingsCommand.ConversationStart -> {
        conversation = true
        Reply("OK, I'll keep quiet. Say carry on when you're done.", Effect.CONVERSATION_START)
      }
      SettingsCommand.ConversationEnd -> {
        conversation = false
        Reply("Carrying on.", Effect.CONVERSATION_END)
      }

      is SettingsCommand.DefineShortcut ->
          when (val r = Shortcuts.define(cmd, store.current.words)) {
            is Shortcuts.Result.Refused -> Reply(r.spoken)
            is Shortcuts.Result.Added -> saved(r.spoken) { it.copy(words = r.words) }
          }
      is SettingsCommand.ForgetShortcut ->
          when (val r = Shortcuts.forget(cmd.phrase, store.current.words)) {
            is Shortcuts.Result.Refused -> Reply(r.spoken)
            is Shortcuts.Result.Added -> saved(r.spoken) { it.copy(words = r.words) }
          }
      SettingsCommand.ListShortcuts ->
          Reply(Shortcuts.listLine(store.current.words).ifEmpty { "You haven't made any shortcuts. Say when I say, a word, then a command." })

      is SettingsCommand.MenuFirst -> menu("${SetupSpeech.toolName(cmd.tool)} first") { w -> w.copy(menuOrder = listOf(cmd.tool) + w.normalisedOrder().filter { it != cmd.tool }) }
      is SettingsCommand.MenuLast -> menu("${SetupSpeech.toolName(cmd.tool)} last") { w -> w.copy(menuOrder = w.normalisedOrder().filter { it != cmd.tool } + cmd.tool) }
      is SettingsCommand.MenuHide -> {
        val hidden = (store.current.words.menuHidden + cmd.tools).distinct()
        if (Words.DEFAULT_MENU.all { it in hidden }) Reply("I'll keep at least one tool on the menu.")
        else menu("${SetupSpeech.list(cmd.tools.map(SetupSpeech::toolName))} hidden. ${capital(SetupSpeech.list(cmd.tools.map(SetupSpeech::toolName)))} still opens if you ask for it") { it.copy(menuHidden = hidden) }
      }
      is SettingsCommand.MenuShow -> menu("${SetupSpeech.list(cmd.tools.map(SetupSpeech::toolName))} back on the menu") { w -> w.copy(menuHidden = w.menuHidden - cmd.tools.toSet()) }
      SettingsCommand.MenuReset -> menu("The menu is back to normal") { it.copy(menuOrder = Words.DEFAULT_MENU, menuHidden = emptyList()) }
      SettingsCommand.WhatsOnMenu -> Reply("Your menu: ${SetupSpeech.list(store.current.words.visibleMenu().map(SetupSpeech::toolName))}.")
      is SettingsCommand.Address -> {
        val name = cmd.name.trim()
        when {
          name.split(' ').size > 2 || name.length < 2 -> Reply("Pick a name of one or two words.")
          CommandCatalog.meaningOf(name) != null -> Reply("$name is already a command. Pick another name.")
          else -> saved("I'll answer to $name too. Say $name, then a command") { it.copy(words = it.words.copy(address = name)) }
        }
      }
      SettingsCommand.AddressForget -> saved("I'll only answer to the usual names") { it.copy(words = it.words.copy(address = null)) }
      is SettingsCommand.TipPacing ->
          tweak(null, capital(cmd.pacing.spoken) + if (cmd.pacing == Pacing.OFF) ". Say help whenever you need it" else "") { it.copy(tips = Tips(cmd.pacing)) }

      is SettingsCommand.SwitchProfile -> outcome(store.switchProfile(cmd.name))
      is SettingsCommand.SaveProfile -> outcome(store.saveProfile(cmd.name))
      SettingsCommand.WhichProfile -> Reply("You're on ${store.activeProfile}." + if (store.hasUnkept) " With changes not kept yet." else "")
      SettingsCommand.ListProfiles -> Reply(store.listProfilesLine() + " Say switch to, then a name.")
      SettingsCommand.Yes -> outcome(store.answerSuggestion(true))
      SettingsCommand.No -> outcome(store.answerSuggestion(false))

      SettingsCommand.WhatDoMyButtons -> Reply(buttonsLine())
      is SettingsCommand.ControlsOn ->
          saved(
              if (!cmd.on) "Glasses controls off"
              else if (env.controlsAvailable) "Glasses controls on. They're experimental. Say what do my buttons do to hear them"
              else "Glasses controls on. This build can't hear the glasses buttons yet, so nothing will happen for now",
          ) { it.copy(controls = it.controls.copy(enabled = cmd.on)) }
      is SettingsCommand.MapButton -> {
        val action = cmd.action
        val known = CommandCatalog.understands(action) || Shortcuts.key(action) in store.current.words.aliases || Shortcuts.key(action) in store.current.words.macros
        if (!known) Reply("I don't know how to $action. Say it the way you'd ask me.")
        else saved("${Controls.SPOKEN_EVENT[cmd.event]} will now: $action") { it.copy(controls = it.controls.copy(map = it.controls.map + (cmd.event to action))) }
      }

      SettingsCommand.ShareSetup -> Reply("Opening the share sheet with your setup.", Effect.SHARE_SETUP)
      SettingsCommand.OpenSettings -> Reply("Settings are on the phone screen now.", Effect.OPEN_SETTINGS)
    }
  }

  /**
   * Faster, slower or an exact speed. In a tool with its own speed (the book, if it has one) that
   * speed changes; otherwise the main one. Session only until "keep that".
   */
  fun changeRate(tool: String?, keep: Boolean = false, requested: (Float) -> Float): Reply {
    val s = store.current.speech
    val override = tool != null && s.tools[tool]?.rate != null
    val before = if (override) s.tools.getValue(tool!!).rate!! else s.rate
    val raw = requested(before)
    val after = Speech.clampRate(raw)
    if (after == before) {
      return Reply(
          when {
            raw > before -> "That's the fastest."
            raw < before -> "That's the slowest."
            else -> "Already ${SetupSpeech.rate(after)} speed."
          },
      )
    }
    val kind = if (after > before) "faster" else "slower"
    val clearNote = if (store.current.ears.clearSpeech && after > ClearSpeechTuning.MAX_RATE) " Clear speech keeps it at 1 times." else ""
    val f: (Setup) -> Setup = {
      if (override) it.copy(speech = it.speech.withTool(tool!!) { t -> t.copy(rate = after) })
      else it.copy(speech = it.speech.copy(rate = after))
    }
    return if (keep) saved("${SetupSpeech.rate(after)} speed$clearNote", f) else tweak(kind, "${SetupSpeech.rate(after)} speed$clearNote", f = f)
  }

  /** A change from the settings screen: saved at once (a helper is deliberately setting it up). */
  fun fromScreen(spoken: String, f: (Setup) -> Setup): Reply = saved(spoken, f)

  fun whatsMySetup(): String {
    val diffs = SetupSpeech.differences(store.current) { name -> env.voices().firstOrNull { it.name == name }?.label ?: "a different voice" }
    val b = StringBuilder()
    if (store.activeProfile != SettingsStore.HOME) b.append("Profile ${store.activeProfile}. ")
    b.append(if (diffs.isEmpty()) "Everything is at the defaults." else "Your setup: " + SetupSpeech.list(diffs) + ".")
    if (store.hasUnkept) b.append(" Not kept yet: ").append(SetupSpeech.list(store.unkeptAreas().map { it.spoken })).append(". Say keep that to keep it.")
    if (store.locked) b.append(" Settings are locked.")
    return b.toString()
  }

  fun buttonsLine(): String {
    val c = store.current.controls
    val lines = Controls.EVENTS.mapNotNull { e -> c.actionFor(e)?.let { "${Controls.SPOKEN_EVENT[e]}: $it" } }
    val b = StringBuilder()
    b.append(if (c.enabled) "Glasses controls are on. " else "Glasses controls are off; say turn on glasses controls. ")
    if (!env.controlsAvailable) b.append("This build can't hear the glasses buttons yet. ")
    b.append(lines.joinToString(". ")).append(". ")
    b.append("Touching and holding the side of the glasses belongs to Meta: it pauses or ends the session.")
    return b.toString()
  }

  // MARK: helpers

  private fun verbosity(explicitTool: String?, openTool: String?, kind: String, f: (Verbosity) -> Verbosity): Reply {
    val s = store.current.speech
    val tool = explicitTool ?: openTool?.takeIf { s.tools[it]?.verbosity != null }
    val before = if (tool != null) s.verbosityFor(tool) else s.verbosity
    val after = f(before)
    if (after == before && explicitTool == null) {
      return Reply(if (kind == "shorter") "That's already the shortest." else if (kind == "more detail") "That's already the most detail." else "Already normal.")
    }
    val spoken = if (tool != null) "${capital(SetupSpeech.toolName(tool))}: ${after.spoken} replies" else "${capital(after.spoken)} replies"
    return tweak(kind, spoken) {
      if (tool != null) it.copy(speech = it.speech.withTool(tool) { t -> t.copy(verbosity = after) })
      else it.copy(speech = it.speech.copy(verbosity = after))
    }
  }

  private fun tryVoice(direction: Int): Reply {
    val voices = env.voices()
    if (voices.size <= 1) {
      tryingVoices = false
      return Reply("There's only one voice for ${env.languageName()} on this phone. You can add voices in the phone's text-to-speech settings.")
    }
    if (!tryingVoices) {
      voiceBefore = store.current.speech.voice
      voiceIndex = voices.indexOfFirst { it.name == voiceBefore }
      tryingVoices = true
    }
    voiceIndex += direction
    if (voiceIndex < 0) {
      tryingVoices = false
      val before = voiceBefore
      return tweak(null, "Back to the voice you had") { it.copy(speech = it.speech.copy(voice = before)) }
    }
    voiceIndex %= voices.size
    val v = voices[voiceIndex]
    val r = tweak(null, "Voice ${voiceIndex + 1} of ${voices.size}, ${v.label}. This is how I sound. Say keep this one, try another voice, or go back", hint = false) {
      it.copy(speech = it.speech.copy(voice = v.name))
    }
    return r
  }

  private fun menu(spoken: String, f: (Words) -> Words): Reply = saved(spoken) { it.copy(words = f(it.words)) }

  /** A voice tweak: this session only. [kind] counts towards a learned suggestion. */
  private fun tweak(kind: String?, spoken: String, hint: Boolean = true, f: (Setup) -> Setup): Reply {
    return when (val o = store.change(spoken, keep = false, f = f)) {
      Outcome.Locked -> locked()
      is Outcome.Unchanged -> Reply(SetupSpeech.sentence("Already ${o.spoken.replaceFirstChar { it.lowercase() }}"))
      is Outcome.Changed -> {
        val b = StringBuilder(SetupSpeech.sentence(o.spoken))
        val suggestion = kind?.let { store.noteTweak(it) }
        if (suggestion != null) b.append(' ').append(suggestion)
        else if (hint && !hintedKeep) {
          hintedKeep = true
          b.append(" Say keep that to keep it.")
        }
        Reply(b.toString())
      }
    }
  }

  /** A deliberate change: saved now, undoable. */
  private fun saved(spoken: String, f: (Setup) -> Setup): Reply =
      when (val o = store.change(spoken, keep = true, f = f)) {
        Outcome.Locked -> locked()
        is Outcome.Unchanged -> Reply(SetupSpeech.sentence(o.spoken))
        is Outcome.Changed -> Reply(SetupSpeech.sentence(o.spoken))
      }

  private fun outcome(o: Outcome, suffix: String = ""): Reply =
      when (o) {
        Outcome.Locked -> locked()
        is Outcome.Unchanged -> Reply(SetupSpeech.sentence(o.spoken.ifEmpty { "OK" }))
        is Outcome.Changed -> Reply(SetupSpeech.sentence(o.spoken) + suffix)
      }

  private fun locked() = Reply("Settings are locked. Say unlock settings first.")

  private fun capital(s: String) = s.replaceFirstChar { it.uppercase() }

  companion object {
    private val VOICE_TRIAL_COMMANDS =
        setOf(SettingsCommand.TryVoice, SettingsCommand.PreviousVoice, SettingsCommand.KeepVoice, SettingsCommand.CancelVoice)
  }
}
