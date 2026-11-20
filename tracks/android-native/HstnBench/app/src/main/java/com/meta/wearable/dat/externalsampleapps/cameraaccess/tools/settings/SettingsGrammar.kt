// SettingsGrammar - every setting by voice
//
// ToolHub tries this after the open tool's grammar and before the global one (and first of all
// while a settings conversation is open: trying voices, a yes/no question, conversation mode), so
// a tool keeps its own meaning for its words. It never claims a phrase the global grammar or a
// tool grammar already uses (SettingsGrammarTest checks). Phrases are in notes/customisation-android.md.
//
// Normalising keeps "right" and "now" (they're fillers elsewhere but mean something here: "move
// it right a bit") and "ok" (an answer to a question). Pure Kotlin, JVM-tested.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings

import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.Phrases

sealed interface SettingsCommand {
  data object Keep : SettingsCommand
  data object Undo : SettingsCommand
  data object WhatsMySetup : SettingsCommand
  /** [area] null = everything. */
  data class Reset(val area: Area?) : SettingsCommand
  data object Lock : SettingsCommand
  data object Unlock : SettingsCommand

  /** [tool] null = the main setting (or the open tool's override, if it has one). */
  data class Shorter(val tool: String? = null) : SettingsCommand
  data class MoreDetail(val tool: String? = null) : SettingsCommand
  data class SetVerbosity(val verbosity: Verbosity, val tool: String? = null) : SettingsCommand
  data class UsePreset(val preset: Preset) : SettingsCommand
  data class ClearSpeech(val on: Boolean) : SettingsCommand
  /** [step] null = back to normal. */
  data class Pitch(val step: Float?) : SettingsCommand
  /** [step] null = no extra pauses. */
  data class Pauses(val step: Int?) : SettingsCommand
  data object SameSpeedEverywhere : SettingsCommand

  data object TryVoice : SettingsCommand
  data object PreviousVoice : SettingsCommand
  data object KeepVoice : SettingsCommand
  data object CancelVoice : SettingsCommand
  data object ListVoices : SettingsCommand
  data object DefaultVoice : SettingsCommand

  data class Earcons(val on: Boolean) : SettingsCommand
  data class EarconVolume(val step: Float) : SettingsCommand
  data class EarconsOnly(val on: Boolean) : SettingsCommand
  data class SpeakEarcons(val on: Boolean) : SettingsCommand

  /** [step] null = back to the middle. Negative = left. */
  data class Balance(val step: Float?) : SettingsCommand
  /** [kind]: "speech", "earcons", "cues" or "all". */
  data class Route(val kind: String, val ear: Ear) : SettingsCommand
  data class Mono(val on: Boolean) : SettingsCommand
  data object ConversationStart : SettingsCommand
  data object ConversationEnd : SettingsCommand

  /** "when I say X, Y": [phrase] null when there was no comma (the store tries each split of [body]). */
  data class DefineShortcut(val phrase: String?, val target: String?, val body: String) : SettingsCommand
  data class ForgetShortcut(val phrase: String) : SettingsCommand
  data object ListShortcuts : SettingsCommand

  data class MenuFirst(val tool: String) : SettingsCommand
  data class MenuLast(val tool: String) : SettingsCommand
  data class MenuHide(val tools: List<String>) : SettingsCommand
  data class MenuShow(val tools: List<String>) : SettingsCommand
  data object MenuReset : SettingsCommand
  data object WhatsOnMenu : SettingsCommand

  data class Address(val name: String) : SettingsCommand
  data object AddressForget : SettingsCommand
  data class TipPacing(val pacing: Pacing) : SettingsCommand

  data class SwitchProfile(val name: String) : SettingsCommand
  data class SaveProfile(val name: String) : SettingsCommand
  data object WhichProfile : SettingsCommand
  data object ListProfiles : SettingsCommand

  data object Yes : SettingsCommand
  data object No : SettingsCommand

  data object WhatDoMyButtons : SettingsCommand
  data class ControlsOn(val on: Boolean) : SettingsCommand
  data class MapButton(val event: String, val action: String) : SettingsCommand

  data object ShareSetup : SettingsCommand
  data object OpenSettings : SettingsCommand
}

/** What's going on, which changes what some short words mean. */
data class SettingsContext(
    /** "try another voice" is under way: "go back", "this one" mean voices. */
    val tryingVoices: Boolean = false,
    /** A yes/no question is waiting. */
    val question: Boolean = false,
    /** Conversation mode: only the way out is listened for. */
    val conversation: Boolean = false,
    /** Profile names ("home", "out and about", "reading", ...). */
    val profiles: Collection<String> = emptyList(),
)

object SettingsGrammar {

  private val FILLERS =
      listOf("please", "um", "umm", "uh", "er", "erm", "can you", "could you", "would you", "will you", "i want you to", "i'd like you to", "just", "thanks", "thank you")

  fun normalize(transcript: String): String = Phrases.normalize(transcript, fillers = FILLERS)

  private const val TOOL = "(?:the )?(book reader|books?|mail reader|mail|letters|post|label reader|labels?|barcodes?|watch for text|watch|light detector|lights?|colou?r detector|colou?rs?)"
  private const val SOUNDS = "(?:the )?(?:sounds?|beeps?|earcons?|tones?|bleeps?)"
  private const val A_BIT = "(?: (a bit|a little|a little bit|slightly|a lot|much more|way more))?"

  fun toolId(word: String): String? {
    val w = word.removePrefix("the ").trim()
    return when {
      w.startsWith("book") -> "book"
      w.startsWith("mail") || w == "letters" || w == "post" -> "mail"
      w.startsWith("label") || w.startsWith("barcode") -> "labels"
      w.startsWith("watch") -> "watch"
      w.startsWith("light") || w.startsWith("colo") -> "light"
      else -> null
    }
  }

  private val TOOL_NAME = Regex("(?:the )?(book reader|books?|mail reader|mail|letters|post|label reader|labels?|barcodes?|watch for text|watch|light detector|lights?|colou?r detector|colou?rs?)")
  private val CONNECTORS = Regex("^(?:\\s|,|and|&|plus|the|from|on|menu|my)*$")

  /** "light and colour", "mail labels watch and light": every word a tool name or a connector. */
  private fun tools(list: String): List<String>? {
    val found = TOOL_NAME.findAll(list).toList()
    if (found.isEmpty()) return null
    var rest = list
    for (m in found.reversed()) rest = rest.removeRange(m.range)
    if (!CONNECTORS.matches(rest)) return null
    return found.mapNotNull { toolId(it.groupValues[1]) }.distinct()
  }

  private fun step(amount: String?): Float =
      when (amount) {
        "a lot", "much more", "way more" -> 0.5f
        null, "" -> 0.2f
        else -> 0.1f
      }

  private class Rule(pattern: String, val build: (MatchResult) -> SettingsCommand?) {
    val regex = Regex("^(?:$pattern)$")
  }

  private val VOICE_TRIAL: List<Rule> =
      listOf(
          Rule("go back|back|previous(?: voice| one)?|the (?:last|previous) (?:voice|one)|last voice|before") { SettingsCommand.PreviousVoice },
          Rule("keep (?:this|that)(?: one| voice)?|keep it|i like (?:this|that)(?: one)?|this one|that one|(?:yes )?that'?s (?:the one|good|fine)|use (?:this|that) (?:one|voice)") { SettingsCommand.KeepVoice },
          Rule("cancel|never mind|stop|forget it|no thanks|the (?:old|original) (?:voice|one)") { SettingsCommand.CancelVoice },
          Rule("next|next one|another|another one|try another|one more") { SettingsCommand.TryVoice },
      )

  private val ANSWERS: List<Rule> =
      listOf(
          Rule("yes(?: please)?|yeah|yep|sure|ok(?:ay)?|do it|go ahead|make it (?:the |my )?default|please do") { SettingsCommand.Yes },
          Rule("no(?: thanks| thank you)?|nope|not now|don'?t|leave it|no don'?t") { SettingsCommand.No },
      )

  private val CONVERSATION_END = Regex("^(?:carry on|go on|continue|resume|i'?m back|back to you|(?:the )?conversation(?:'s| is)? over|(?:we'?re|i'?m) done talking|end conversation(?: mode)?|stop conversation mode|you can talk(?: again)?|ok carry on)$")

  private val RULES: List<Rule> =
      listOf(
          // Keep, undo, setup, reset, lock.
          Rule("keep (?:that|it|this|those|these|them)(?: settings?| change)?|save (?:that|those|these|my) (?:settings?|changes?)|save that|remember (?:that|this)|make (?:that|this|it) (?:the |my )?default") { SettingsCommand.Keep },
          Rule("undo(?: that| it)?|put it back(?: how it was)?|change it back|go back to how it was|that'?s worse|undo (?:the )?last change") { SettingsCommand.Undo },
          Rule("what'?s my setup|what is my setup|what are my settings|my settings|what have i changed|what did i change|how am i set up|what'?s different|read (?:me )?my settings|tell me my setup") { SettingsCommand.WhatsMySetup },
          Rule("reset (?:all|everything|all (?:my |the )?settings|my setup|the whole setup)|factory reset|reset (?:all|everything) to (?:the )?defaults?") { SettingsCommand.Reset(null) },
          Rule("reset (?:the |my )?(speech|voice|talking|sounds?|beeps|earcons|ears|balance|words|shortcuts|routines|controls|buttons|glasses controls|tips|reminders|descriptions)(?: settings)?(?: to (?:the )?defaults?)?") { m ->
            SettingsCommand.Reset(
                when (m.groupValues[1]) {
                  "speech", "voice", "talking" -> Area.SPEECH
                  "sound", "sounds", "beeps", "earcons" -> Area.SOUNDS
                  "ears", "balance" -> Area.EARS
                  "words", "shortcuts", "routines" -> Area.WORDS
                  "controls", "buttons", "glasses controls" -> Area.CONTROLS
                  "tips", "reminders" -> Area.TIPS
                  else -> Area.DESCRIPTIONS
                },
            )
          },
          Rule("lock (?:my |the )?(?:settings|setup)|lock settings") { SettingsCommand.Lock },
          Rule("unlock (?:my |the )?(?:settings|setup)|unlock settings") { SettingsCommand.Unlock },

          // Detail.
          Rule("$TOOL (?:shorter|short|brief|briefer)|(?:make|keep) $TOOL (?:shorter|short|brief)|shorter (?:for|in) $TOOL") { m ->
            toolId(m.groupValues.drop(1).first { it.isNotEmpty() })?.let { SettingsCommand.Shorter(it) }
          },
          Rule("$TOOL (?:more detailed|detailed|more detail)|(?:make|keep) $TOOL (?:more )?detailed|more detail (?:for|in) $TOOL") { m ->
            toolId(m.groupValues.drop(1).first { it.isNotEmpty() })?.let { SettingsCommand.MoreDetail(it) }
          },
          Rule("$TOOL (?:normal detail|normal length)|(?:make|keep) $TOOL normal") { m ->
            toolId(m.groupValues.drop(1).first { it.isNotEmpty() })?.let { SettingsCommand.SetVerbosity(Verbosity.NORMAL, it) }
          },
          Rule("shorter|be (?:more )?brief|briefer|less detail|less talking|(?:say|talk) less|shorter (?:replies|answers)|keep it short|too much (?:talking|detail)") { SettingsCommand.Shorter() },
          Rule("more detail(?:ed)?|(?:give me |i want )?more detail|(?:say|talk) more|longer (?:replies|answers)|more words|not enough detail") { SettingsCommand.MoreDetail() },
          Rule("normal (?:detail|replies|length)") { SettingsCommand.SetVerbosity(Verbosity.NORMAL) },

          // Presets, clear speech, pitch, pauses.
          Rule("(?:use |switch to |be |make it )?(brisk|gentle)(?: speech| voice| preset| mode| please)?|(?:use |switch to )?(?:the )?(brisk|gentle|normal) (?:speech|preset|voice preset)") { m ->
            Preset.fromId(m.groupValues.drop(1).first { it.isNotEmpty() })?.let { SettingsCommand.UsePreset(it) }
          },
          Rule("(?:turn on |use |switch on )?clear(?:er)? speech(?: on| please)?|speak (?:more )?clearly|clearer|clearer voice") { SettingsCommand.ClearSpeech(true) },
          Rule("(?:turn off |switch off |no )clear speech|clear speech off") { SettingsCommand.ClearSpeech(false) },
          Rule("(?:a )?(?:bit |little )?higher (?:pitch|voice)|raise (?:the |your )?pitch|pitch up|higher") { SettingsCommand.Pitch(0.1f) },
          Rule("(?:a )?(?:bit |little )?lower (?:pitch|voice)|lower (?:the |your )?pitch|pitch down|deeper(?: voice)?") { SettingsCommand.Pitch(-0.1f) },
          Rule("normal pitch|(?:reset|normal) (?:the |your )?pitch|pitch normal") { SettingsCommand.Pitch(null) },
          Rule("longer pauses|more pauses|(?:pause|wait) (?:more|longer) between sentences|bigger pauses|slow pauses") { SettingsCommand.Pauses(150) },
          Rule("shorter pauses|less pauses|fewer pauses|smaller pauses") { SettingsCommand.Pauses(-150) },
          Rule("no (?:extra )?pauses|normal pauses|(?:turn off|stop) (?:the )?pauses") { SettingsCommand.Pauses(null) },
          Rule("(?:use )?(?:the )?same speed everywhere|(?:use )?(?:my |the )?(?:main|normal|usual) speed (?:for|in) (?:the )?books?|books? at (?:the )?same speed") { SettingsCommand.SameSpeedEverywhere },

          // Voices.
          Rule("try (?:another|a different|a new) voice|(?:another|a different|a new|next) voice|change (?:the |your )?voice|(?:can i |let me )?hear (?:another|other|the other) voices?|try (?:the )?other voices") { SettingsCommand.TryVoice },
          Rule("what voices (?:are there|do you have|can i (?:have|use))|list (?:the |all )?voices|how many voices(?: are there)?|which voices") { SettingsCommand.ListVoices },
          Rule("(?:use |go back to |back to )?(?:the )?(?:default|normal|usual|original) voice") { SettingsCommand.DefaultVoice },

          // Sounds.
          Rule("(?:turn |switch )?$SOUNDS off|(?:turn|switch) off $SOUNDS|no $SOUNDS|mute $SOUNDS|stop (?:the )?(?:beeps|beeping|sounds)") { SettingsCommand.Earcons(false) },
          Rule("(?:turn |switch )?$SOUNDS (?:back )?on|(?:turn|switch) on $SOUNDS|$SOUNDS back") { SettingsCommand.Earcons(true) },
          Rule("louder $SOUNDS|$SOUNDS louder|(?:turn )?$SOUNDS up|(?:make )?$SOUNDS (?:a bit )?louder") { SettingsCommand.EarconVolume(0.1f) },
          Rule("(?:quieter|softer) $SOUNDS|$SOUNDS (?:quieter|softer)|(?:turn )?$SOUNDS down|(?:make )?$SOUNDS (?:a bit )?(?:quieter|softer)") { SettingsCommand.EarconVolume(-0.1f) },
          Rule("(?:just|only) (?:the )?(?:sounds|beeps|earcons)|(?:sounds|beeps|earcons) only|(?:use )?sounds instead of words|fewer words") { SettingsCommand.EarconsOnly(true) },
          Rule("words again|(?:talk|speak) to me again|(?:use )?words instead of sounds|(?:turn off|stop) (?:sounds|beeps|earcons) only") { SettingsCommand.EarconsOnly(false) },
          Rule("(?:say|tell me) what (?:the )?(?:sounds|beeps|earcons) mean|say the (?:sounds|beeps)|(?:speak|say) (?:the )?(?:sounds|beeps|earcons) (?:as words|out loud)") { SettingsCommand.SpeakEarcons(true) },
          Rule("(?:stop saying|don'?t say) (?:the |what the )?(?:sounds|beeps|earcons)(?: mean)?|(?:play|use) (?:the )?(?:sounds|beeps) again") { SettingsCommand.SpeakEarcons(false) },

          // Ears.
          Rule("(?:move|put|shift|pan) (?:it|the sound|the balance|the sound balance|everything|sound)? ?(?:to (?:the |my )?|more to (?:the |my )?)?(left|right)$A_BIT(?: ear)?") { m ->
            val s = step(m.groupValues[2])
            SettingsCommand.Balance(if (m.groupValues[1] == "left") -s else s)
          },
          Rule("more (?:in|to) (?:my |the )?(left|right)(?: ear)?|balance (?:to the )?(left|right)$A_BIT") { m ->
            val side = m.groupValues[1].ifEmpty { m.groupValues[2] }
            val s = step(m.groupValues.getOrNull(3))
            SettingsCommand.Balance(if (side == "left") -s else s)
          },
          Rule("(?:centre|center|middle) (?:the )?(?:sound|balance)|balance (?:in )?(?:the )?(?:middle|centre|center)|(?:reset|normal) (?:the )?balance|sound in the middle") { SettingsCommand.Balance(null) },
          Rule("(?:put )?(?:the )?(speech|voice|talking|sounds|beeps|earcons|direction cues|cues|directions|everything|all sounds?) (?:in|to|into) (?:my )?(left|right|both)(?: ear| ears| sides)?") { m ->
            val kind =
                when (m.groupValues[1]) {
                  "speech", "voice", "talking" -> "speech"
                  "sounds", "beeps", "earcons" -> "earcons"
                  "direction cues", "cues", "directions" -> "cues"
                  else -> "all"
                }
            SettingsCommand.Route(kind, Ear.fromId(m.groupValues[2]) ?: Ear.BOTH)
          },
          Rule("i (?:use|have|listen in|hear in) mono|mono(?: on| please| mode)?|(?:turn|switch) on mono|i only hear (?:in )?one (?:ear|side)") { SettingsCommand.Mono(true) },
          Rule("i (?:use|have|listen in) stereo|stereo(?: please| mode)?|mono off|(?:turn|switch) off mono|i hear (?:in )?both (?:ears|sides)") { SettingsCommand.Mono(false) },
          Rule("someone'?s talking to me|some ?(?:one|body) is talking to me|i'?m (?:talking|chatting|speaking) (?:to|with) (?:someone|somebody|a person)|conversation mode|i'?m in a conversation|hold on someone'?s talking") { SettingsCommand.ConversationStart },

          // Words: shortcuts, routines, the menu, the address word.
          Rule("(?:forget|delete|remove|drop) (?:the |my )?(?:shortcut|routine|macro) (?:called |for )?(.+)") { m -> SettingsCommand.ForgetShortcut(m.groupValues[1].trim()) },
          Rule("what are my (?:shortcuts|routines|macros)|list (?:my )?(?:shortcuts|routines|macros)|what (?:shortcuts|routines) do i have|my (?:shortcuts|routines)") { SettingsCommand.ListShortcuts },
          Rule("(?:put|move) $TOOL (?:first|to the (?:top|start|front|beginning))|$TOOL first") { m ->
            toolId(m.groupValues.drop(1).first { it.isNotEmpty() })?.let { SettingsCommand.MenuFirst(it) }
          },
          Rule("(?:put|move) $TOOL (?:last|to the (?:end|bottom|back))|$TOOL last") { m ->
            toolId(m.groupValues.drop(1).first { it.isNotEmpty() })?.let { SettingsCommand.MenuLast(it) }
          },
          Rule("hide (.+?)(?: from (?:the |my )?menu)?") { m -> tools(m.groupValues[1])?.let { SettingsCommand.MenuHide(it) } },
          Rule("(?:show|unhide) (.+?) (?:in|on) (?:the |my )?menu|unhide (.+)") { m ->
            tools(m.groupValues[1].ifEmpty { m.groupValues[2] })?.let { SettingsCommand.MenuShow(it) }
          },
          Rule("reset (?:the |my )?menu|menu back to normal|(?:show|put back) (?:all|every) (?:the )?tools") { SettingsCommand.MenuReset },
          Rule("what'?s on (?:my |the )?menu|read (?:me )?(?:my |the )?menu|which tools are on (?:my |the )?menu") { SettingsCommand.WhatsOnMenu },
          Rule("(?:call yourself|your name is|answer to|i'?ll call you|i will call you|i'?m going to call you) ([a-z']+(?: [a-z']+)?)") { m -> SettingsCommand.Address(m.groupValues[1]) },
          Rule("forget your name|(?:stop answering to|don'?t answer to) [a-z' ]+|no name") { SettingsCommand.AddressForget },

          // Tips.
          Rule("(?:fewer|less) (?:tips|reminders|hints)|tips less often|(?:remind me|nudge me) less(?: often)?") { SettingsCommand.TipPacing(Pacing.FEWER) },
          Rule("no (?:more )?(?:tips|reminders|hints)|(?:tips|reminders|hints) off|(?:turn off|stop) (?:the )?(?:tips|reminders|hints)|stop reminding me") { SettingsCommand.TipPacing(Pacing.OFF) },
          Rule("(?:normal|more) (?:tips|reminders|hints)|(?:tips|reminders|hints) (?:back )?on|(?:turn on|start) (?:the )?(?:tips|reminders)") { SettingsCommand.TipPacing(Pacing.NORMAL) },

          // Profiles (switching is in [profileRule], it needs the names).
          Rule("save (?:this|these settings|my settings|my setup|it|this setup)? ?as (?:a )?(?:new )?(?:profile )?(?:called |named )?(.+?)(?: profile)?|save (?:a )?(?:new )?profile (?:called |named |as )?(.+)") { m ->
            SettingsCommand.SaveProfile(m.groupValues[1].ifEmpty { m.groupValues[2] }.trim())
          },
          Rule("which profile(?: am i (?:on|using|in))?|what profile(?: am i (?:on|using|in))?|what profile is (?:this|on)") { SettingsCommand.WhichProfile },
          Rule("list (?:my |the )?profiles|what profiles (?:do i have|are there)|my profiles") { SettingsCommand.ListProfiles },

          // Glasses controls (Experimental).
          Rule("what do (?:my |the )?(?:glasses )?(?:buttons|controls) do|what are my (?:glasses )?(?:buttons|controls)|read (?:me )?my (?:buttons|controls)") { SettingsCommand.WhatDoMyButtons },
          Rule("(?:turn on|enable|use|switch on) (?:the )?glasses (?:buttons|controls)|glasses (?:buttons|controls) on") { SettingsCommand.ControlsOn(true) },
          Rule("(?:turn off|disable|switch off) (?:the )?glasses (?:buttons|controls)|glasses (?:buttons|controls) off") { SettingsCommand.ControlsOn(false) },

          // Sharing and the screen.
          Rule("(?:share|export|send) (?:my |this )?(?:setup|settings)") { SettingsCommand.ShareSetup },
          Rule("(?:open|show)(?: me)? (?:my |the )?settings(?: screen)?|settings(?: screen)?|customi[sz]e|make it (?:my|your) own") { SettingsCommand.OpenSettings },
      )

  private val SHORTCUT = Regex("^(?:when|if|whenever) i say (.+)$")
  private val BUTTON =
      Regex(
          "^(?:when|if|whenever) i (press|short press|press the capture button|press the button|hold|hold the capture button|hold the button|double press|double press the capture button|double tap|tap|tap the touchpad|swipe forward|swipe up|swipe back|swipe down|swipe left|swipe right|press the action button)(?: the)?(?: capture)?(?: button)? (.+)$",
      )

  /** The settings command in [transcript], or null. */
  fun parse(transcript: String, context: SettingsContext = SettingsContext()): SettingsCommand? {
    val text = normalize(transcript)
    if (text.isEmpty()) return null
    if (context.conversation) {
      return if (CONVERSATION_END.matches(text)) SettingsCommand.ConversationEnd else null
    }
    if (context.question) match(ANSWERS, text)?.let { return it }
    if (context.tryingVoices) match(VOICE_TRIAL, text)?.let { return it }
    shortcut(transcript)?.let { return it }
    button(text)?.let { return it }
    match(RULES, text)?.let { return it }
    return profileRule(text, context.profiles)
  }

  private fun match(rules: List<Rule>, text: String): SettingsCommand? {
    for (rule in rules) {
      val m = rule.regex.matchEntire(text) ?: continue
      rule.build(m)?.let { return it }
    }
    return null
  }

  /** "when I say post, open the mail reader": the comma (if heard) splits phrase from command. */
  private fun shortcut(transcript: String): SettingsCommand? {
    val lower = transcript.lowercase().replace('’', '\'').replace(Regex("[\"“”]"), "").trim().trimEnd('.', '!')
    val stripped = lower.replace(Regex("^(?:hey |ok |okay )?(?:the )?(?:book reader|reader|glasses|app|assistant)[, ]+"), "")
    val m = SHORTCUT.find(stripped) ?: return null
    val body = m.groupValues[1].trim()
    val cut = Regex("[,:;]| - ").find(body)
    val phrase = cut?.let { normalize(body.substring(0, it.range.first)) }?.takeIf { it.isNotEmpty() }
    val target = cut?.let { body.substring(it.range.last + 1).trim() }?.takeIf { it.isNotEmpty() }
    return SettingsCommand.DefineShortcut(phrase, target, Phrases.light(body))
  }

  private fun button(text: String): SettingsCommand? {
    val m = BUTTON.find(text) ?: return null
    val event =
        when (m.groupValues[1]) {
          "press", "short press", "press the capture button", "press the button" -> "captureShort"
          "hold", "hold the capture button", "hold the button" -> "captureHold"
          "double press", "double press the capture button", "double tap" -> "captureDouble"
          "tap", "tap the touchpad" -> "select"
          "swipe forward", "swipe up" -> "navUp"
          "swipe back", "swipe down" -> "navDown"
          "swipe left" -> "navLeft"
          "swipe right" -> "navRight"
          "press the action button" -> "action"
          else -> return null
        }
    val action = m.groupValues[2].removePrefix("button ").removePrefix("it ").trim()
    return SettingsCommand.MapButton(event, action)
  }

  /** "switch to out and about", "use the reading profile", "reading profile", "home profile". */
  private fun profileRule(text: String, profiles: Collection<String>): SettingsCommand? {
    val m =
        // Not "start" or "go to": "start reading" and "go to reading" mean the book.
        Regex("^(?:(?:switch|change) (?:over )?to|use)(?: the| my)? (.+?)(?: profile| settings| mode)?$").find(text)
            ?: Regex("^(?:the |my )?(.+?) (?:profile|mode)(?: please)?$").find(text)
            ?: return null
    val name = m.groupValues[1].trim()
    return profiles.firstOrNull { it == name }?.let { SettingsCommand.SwitchProfile(it) }
  }
}
