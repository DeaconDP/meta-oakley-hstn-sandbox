// SetupSpeech - how settings are said out loud
//
// "What's my setup?" speaks only what differs from the defaults, area by area (design rule 3), and
// speech is described against its preset ("Brisk, but slower: 1.2 times"). Every change speaks its
// new value with the same words. English only, like the grammars. Pure Kotlin, JVM-tested.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings

import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

object SetupSpeech {

  val TOOL_NAMES =
      mapOf("book" to "the book", "mail" to "mail", "labels" to "labels", "watch" to "watch for text", "light" to "light")

  fun toolName(id: String): String = TOOL_NAMES[id] ?: id

  fun rate(r: Float): String =
      if (r % 1f == 0f) "${r.toInt()} times" else String.format(Locale.US, "%.2f", r).trimEnd('0') + " times"

  fun percent(v: Float): String = "${(v * 100).roundToInt()} percent"

  fun pitch(p: Float): String =
      when {
        p == 1f -> "normal pitch"
        p > 1f -> "higher pitch, " + String.format(Locale.US, "%.1f", p)
        else -> "lower pitch, " + String.format(Locale.US, "%.1f", p)
      }

  fun pauses(ms: Int): String =
      when {
        ms == 0 -> "no extra pauses"
        ms <= 200 -> "short pauses"
        ms <= 450 -> "longer pauses"
        else -> "long pauses"
      }

  fun balance(b: Float): String =
      when {
        b == 0f -> "balance in the middle"
        b < 0f -> "balance ${percent(abs(b))} to the left"
        else -> "balance ${percent(b)} to the right"
      }

  fun ear(kind: String, e: Ear): String =
      when (e) {
        Ear.BOTH -> "$kind in both ears"
        Ear.LEFT -> "$kind in your left ear"
        Ear.RIGHT -> "$kind in your right ear"
      }

  fun ticks(s: Int): String = if (s == 0) "watch ticks off" else "watch ticks every $s seconds"

  fun list(items: List<String>): String =
      when (items.size) {
        0 -> ""
        1 -> items[0]
        else -> items.dropLast(1).joinToString(", ") + " and " + items.last()
      }

  /** Speech, against its preset: "Brisk speech", "speed 1.6 times", "the book at 1.2 times". */
  fun speech(s: Speech, voiceName: (String) -> String = { "a different voice" }): List<String> {
    val out = mutableListOf<String>()
    val p = s.preset
    if (p != Preset.NORMAL) out += "${p.spoken} speech"
    val but = if (p != Preset.NORMAL) "but " else ""
    if (s.rate != p.rate) out += "${but}speed ${rate(s.rate)}"
    if (s.pitch != p.pitch) out += pitch(s.pitch)
    if (s.pauseMs != p.pauseMs) out += pauses(s.pauseMs)
    if (s.verbosity != p.verbosity) out += "${s.verbosity.spoken} replies"
    s.voice?.let { out += voiceName(it) }
    s.locale?.let { out += "language ${Locale.forLanguageTag(it).getDisplayName(Locale.UK)}" }
    for ((id, t) in s.tools.toSortedMap()) {
      t.rate?.let { out += "${toolName(id)} at ${rate(it)}" }
      t.verbosity?.let { out += "${toolName(id)} ${it.spoken}" }
      if (t.pageNumbers == true) out += "page numbers read out"
      if (t.autoTurn == false) out += "automatic page turns off"
    }
    return out
  }

  fun sounds(s: Sounds): List<String> {
    val d = Sounds()
    val out = mutableListOf<String>()
    if (!s.earcons) out += "sounds off"
    else if (s.volume != d.volume) out += "sounds at ${percent(s.volume)}"
    if (s.earconsOnly) out += "sounds instead of short replies"
    if (s.speakEarcons) out += "sounds said as words"
    if (s.watchTickSeconds != d.watchTickSeconds) out += ticks(s.watchTickSeconds)
    return out
  }

  fun ears(e: Ears): List<String> {
    val out = mutableListOf<String>()
    if (e.balance != 0f) out += balance(e.balance)
    if (e.speech != Ear.BOTH) out += ear("speech", e.speech)
    if (e.earcons != Ear.BOTH) out += ear("sounds", e.earcons)
    if (e.cues != Ear.BOTH) out += ear("direction cues", e.cues)
    if (e.mono) out += "mono"
    if (e.clearSpeech) out += "clear speech on"
    return out
  }

  fun words(w: Words): List<String> {
    val out = mutableListOf<String>()
    if (w.aliases.isNotEmpty()) out += shortcutCount(w.aliases.size, "shortcut") + ": " + list(w.aliases.keys.toList())
    if (w.macros.isNotEmpty()) out += shortcutCount(w.macros.size, "routine") + ": " + list(w.macros.keys.toList())
    if (w.normalisedOrder() != Words.DEFAULT_MENU) out += "menu order " + list(w.normalisedOrder().map(::toolName))
    if (w.menuHidden.isNotEmpty()) out += list(w.menuHidden.map(::toolName)) + " hidden from the menu"
    w.address?.let { out += "I answer to $it" }
    return out
  }

  fun controls(c: Controls): List<String> {
    val out = mutableListOf<String>()
    if (c.enabled) out += "glasses controls on"
    val changed = Controls.EVENTS.filter { c.map[it] != Controls.DEFAULT_MAP[it] }
    if (changed.isNotEmpty()) out += shortcutCount(changed.size, "button") + " changed"
    return out
  }

  fun tips(t: Tips): List<String> = if (t.pacing == Pacing.NORMAL) emptyList() else listOf(t.pacing.spoken)

  fun descriptions(d: Descriptions): List<String> {
    val out = mutableListOf<String>()
    if (d.detail != Verbosity.NORMAL) out += "${d.detail.spoken} descriptions"
    if (!d.textFirst) out += "text not read first"
    if (!d.colours) out += "colours skipped"
    if (d.directions == "clock") out += "clock-face directions"
    return out
  }

  fun area(a: Area, s: Setup, voiceName: (String) -> String = { "a different voice" }): List<String> =
      when (a) {
        Area.SPEECH -> speech(s.speech, voiceName)
        Area.SOUNDS -> sounds(s.sounds)
        Area.EARS -> ears(s.ears)
        Area.WORDS -> words(s.words)
        Area.CONTROLS -> controls(s.controls)
        Area.TIPS -> tips(s.tips)
        Area.DESCRIPTIONS -> descriptions(s.descriptions)
      }

  /** Everything that differs from the defaults, one phrase each. */
  fun differences(s: Setup, voiceName: (String) -> String = { "a different voice" }): List<String> =
      Area.entries.flatMap { area(it, s, voiceName) }

  private fun shortcutCount(n: Int, what: String) = if (n == 1) "1 $what" else "$n ${what}s"

  /** The first sentence of [text] (short replies). "1.5 times." isn't cut at its decimal point. */
  fun firstSentence(text: String): String {
    val t = text.trim()
    val m = Regex("^(.+?[.!?])(?=\\s+[A-Z]|$)").find(t) ?: return t
    return m.groupValues[1]
  }

  /** "Speech 1.4 times" style capitalisation for the start of a reply. */
  fun sentence(s: String): String = s.replaceFirstChar { it.titlecase(Locale.UK) }.let { if (it.endsWith(".") || it.endsWith("?")) it else "$it." }
}
