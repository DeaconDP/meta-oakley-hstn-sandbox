// Setup - every "Make it your own" setting, as one value (notes/customisation-android.md)
//
// One versioned shape shared with iOS (schema 1). Seven areas, each its own data class with a
// tolerant reader (unknown fields ignored, missing fields default) and a full writer:
//
//   speech        preset, rate (0.5-3x multiplier, the one scale both platforms use), pitch, pause
//                 length, verbosity, voice, locale, and per-tool overrides (book rate, page numbers...)
//   sounds        earcons on/off, volume, earcons only, speak instead of earcons, watch ticks
//   ears          balance, which ear for speech / earcons / direction cues, mono, clear speech
//   words         aliases, macros, home-menu order and hidden tools, address word
//   controls      glasses button map (Experimental)
//   tips          reminder pacing
//   descriptions  detail and description preferences (kept for iOS parity; no Android tool uses them yet)
//
// No setting here can switch off "can't tell", the medicine and money refusals, or face blur, and
// none ever will (notes/customisation-roadmap.md > Not doing). Pure Kotlin, JVM-tested.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings

import java.util.Locale

/** One group of settings. [id] is the stable key in storage, profiles and export codes. */
enum class Area(val id: String, val spoken: String) {
  SPEECH("speech", "speech"),
  SOUNDS("sounds", "sounds"),
  EARS("ears", "ears"),
  WORDS("words", "words"),
  CONTROLS("controls", "glasses controls"),
  TIPS("tips", "tips"),
  DESCRIPTIONS("descriptions", "descriptions");

  companion object {
    fun fromId(id: String?): Area? = entries.firstOrNull { it.id == id }

    /** Areas a profile switches. Words and controls are yours in every profile. */
    val PROFILE_AREAS = listOf(SPEECH, SOUNDS, EARS, TIPS, DESCRIPTIONS)
  }
}

enum class Verbosity(val id: String, val spoken: String) {
  SHORT("short", "short"),
  NORMAL("normal", "normal"),
  DETAILED("detailed", "detailed");

  fun shorter(): Verbosity = entries[(ordinal - 1).coerceAtLeast(0)]

  fun longer(): Verbosity = entries[(ordinal + 1).coerceAtMost(entries.lastIndex)]

  companion object {
    fun fromId(id: Any?): Verbosity? = entries.firstOrNull { it.id == id }
  }
}

/** Which ear a kind of sound plays in. */
enum class Ear(val id: String) {
  BOTH("both"),
  LEFT("left"),
  RIGHT("right");

  companion object {
    fun fromId(id: Any?): Ear? = entries.firstOrNull { it.id == id }
  }
}

/** How often spoken tips and silence reminders come. */
enum class Pacing(val id: String, val spoken: String) {
  FEWER("fewer", "fewer tips"),
  NORMAL("normal", "normal tips"),
  OFF("off", "tips off");

  companion object {
    fun fromId(id: Any?): Pacing? = entries.firstOrNull { it.id == id }
  }
}

/** Speech presets: start here, then tweak ("Brisk, but slower"). */
enum class Preset(val id: String, val spoken: String, val rate: Float, val pitch: Float, val pauseMs: Int, val verbosity: Verbosity) {
  BRISK("brisk", "Brisk", 1.4f, 1f, 0, Verbosity.SHORT),
  NORMAL("normal", "Normal", 1f, 1f, 0, Verbosity.NORMAL),
  GENTLE("gentle", "Gentle", 0.85f, 0.95f, 300, Verbosity.DETAILED);

  companion object {
    fun fromId(id: Any?): Preset? = entries.firstOrNull { it.id == id }
  }
}

/** Per-tool overrides layered on the main speech settings. Null = use the main value. */
data class ToolSpeech(
    val rate: Float? = null,
    val verbosity: Verbosity? = null,
    /** Book only: read page numbers, headers and footers. */
    val pageNumbers: Boolean? = null,
    /** Book only: read the next page by itself when a page turn is seen. */
    val autoTurn: Boolean? = null,
) {
  val isEmpty: Boolean
    get() = rate == null && verbosity == null && pageNumbers == null && autoTurn == null

  fun toMap(): Map<String, Any?> =
      linkedMapOf<String, Any?>().apply {
        rate?.let { put("rate", it.toDouble()) }
        verbosity?.let { put("verbosity", it.id) }
        pageNumbers?.let { put("pageNumbers", it) }
        autoTurn?.let { put("autoTurn", it) }
      }

  companion object {
    fun fromMap(m: Map<*, *>): ToolSpeech =
        ToolSpeech(
            rate = num(m["rate"])?.let { Speech.clampRate(it) },
            verbosity = Verbosity.fromId(m["verbosity"]),
            pageNumbers = m["pageNumbers"] as? Boolean,
            autoTurn = m["autoTurn"] as? Boolean,
        )
  }
}

data class Speech(
    val preset: Preset = Preset.NORMAL,
    /** Multiplier, 1 = the engine's normal speed. Same scale on iOS. */
    val rate: Float = 1f,
    /** Multiplier, 1 = the voice's own pitch. */
    val pitch: Float = 1f,
    /** Extra silence after each sentence of tool content, in milliseconds. */
    val pauseMs: Int = 0,
    val verbosity: Verbosity = Verbosity.NORMAL,
    /** Installed voice name (Android Voice.name), null = the engine's default for [locale]. */
    val voice: String? = null,
    /** BCP-47 tag, null = the device language (falling back to US English). */
    val locale: String? = null,
    /** Keyed by ToolId.id. */
    val tools: Map<String, ToolSpeech> = emptyMap(),
) {
  fun tool(id: String): ToolSpeech = tools[id] ?: ToolSpeech()

  fun rateFor(tool: String?): Float = tool?.let { tools[it]?.rate } ?: rate

  fun verbosityFor(tool: String?): Verbosity = tool?.let { tools[it]?.verbosity } ?: verbosity

  fun withTool(id: String, f: (ToolSpeech) -> ToolSpeech): Speech {
    val t = f(tool(id))
    return copy(tools = if (t.isEmpty) tools - id else tools + (id to t))
  }

  fun toMap(): Map<String, Any?> =
      linkedMapOf(
          "preset" to preset.id,
          "rate" to rate.toDouble(),
          "pitch" to pitch.toDouble(),
          "pauseMs" to pauseMs.toLong(),
          "verbosity" to verbosity.id,
          "voice" to voice,
          "locale" to locale,
          "tools" to tools.toSortedMap().mapValues { it.value.toMap() },
      )

  companion object {
    const val MIN_RATE = 0.5f
    const val MAX_RATE = 3f
    const val MIN_PITCH = 0.5f
    const val MAX_PITCH = 2f
    const val MAX_PAUSE_MS = 1500

    /** Rates are kept to one decimal place, as the voice commands always have. */
    fun clampRate(r: Float): Float = (Math.round(r * 10f) / 10f).coerceIn(MIN_RATE, MAX_RATE)

    fun clampPitch(p: Float): Float = (Math.round(p * 10f) / 10f).coerceIn(MIN_PITCH, MAX_PITCH)

    fun fromMap(m: Map<*, *>): Speech {
      val d = Speech()
      val tools =
          (m["tools"] as? Map<*, *>)?.entries?.mapNotNull { (k, v) ->
            val key = k as? String ?: return@mapNotNull null
            val t = (v as? Map<*, *>)?.let { ToolSpeech.fromMap(it) } ?: return@mapNotNull null
            if (t.isEmpty) null else key to t
          }?.toMap() ?: d.tools
      return Speech(
          preset = Preset.fromId(m["preset"]) ?: d.preset,
          rate = num(m["rate"])?.let { clampRate(it) } ?: d.rate,
          pitch = num(m["pitch"])?.let { clampPitch(it) } ?: d.pitch,
          pauseMs = num(m["pauseMs"])?.toInt()?.coerceIn(0, MAX_PAUSE_MS) ?: d.pauseMs,
          verbosity = Verbosity.fromId(m["verbosity"]) ?: d.verbosity,
          voice = (m["voice"] as? String)?.takeIf { it.isNotBlank() },
          locale = (m["locale"] as? String)?.takeIf { it.isNotBlank() },
          tools = tools,
      )
    }
  }
}

data class Sounds(
    val earcons: Boolean = true,
    /** 0..1. */
    val volume: Float = 0.8f,
    /** Familiar confirmations ("Paused.", "Main menu.", a tool's name) are a sound, not words. */
    val earconsOnly: Boolean = false,
    /** While learning: say what a sound means ("found", "error") instead of playing it. */
    val speakEarcons: Boolean = false,
    /** Watch for text's "still watching" tick, in seconds; 0 = off. */
    val watchTickSeconds: Int = DEFAULT_WATCH_TICK_S,
) {
  fun toMap(): Map<String, Any?> =
      linkedMapOf(
          "earcons" to earcons,
          "volume" to volume.toDouble(),
          "earconsOnly" to earconsOnly,
          "speakEarcons" to speakEarcons,
          "watchTickSeconds" to watchTickSeconds.toLong(),
      )

  companion object {
    const val DEFAULT_WATCH_TICK_S = 10

    fun fromMap(m: Map<*, *>): Sounds {
      val d = Sounds()
      return Sounds(
          earcons = m["earcons"] as? Boolean ?: d.earcons,
          volume = num(m["volume"])?.let { round2(it).coerceIn(0f, 1f) } ?: d.volume,
          earconsOnly = m["earconsOnly"] as? Boolean ?: d.earconsOnly,
          speakEarcons = m["speakEarcons"] as? Boolean ?: d.speakEarcons,
          watchTickSeconds = num(m["watchTickSeconds"])?.toInt()?.coerceIn(0, 600) ?: d.watchTickSeconds,
      )
    }
  }
}

data class Ears(
    /** -1 = all left, 0 = centre, 1 = all right. */
    val balance: Float = 0f,
    val speech: Ear = Ear.BOTH,
    val earcons: Ear = Ear.BOTH,
    /** Direction cues (Watch for text's left/right tone). */
    val cues: Ear = Ear.BOTH,
    /** "I use mono": no left/right panning; direction cues become pitch plus words. */
    val mono: Boolean = false,
    /** Clear speech: compressed, a little louder and brighter, and never faster than 1x. */
    val clearSpeech: Boolean = false,
) {
  fun toMap(): Map<String, Any?> =
      linkedMapOf(
          "balance" to balance.toDouble(),
          "speech" to speech.id,
          "earcons" to earcons.id,
          "cues" to cues.id,
          "mono" to mono,
          "clearSpeech" to clearSpeech,
      )

  companion object {
    fun fromMap(m: Map<*, *>): Ears {
      val d = Ears()
      return Ears(
          balance = num(m["balance"])?.let { round2(it).coerceIn(-1f, 1f) } ?: d.balance,
          speech = Ear.fromId(m["speech"]) ?: d.speech,
          earcons = Ear.fromId(m["earcons"]) ?: d.earcons,
          cues = Ear.fromId(m["cues"]) ?: d.cues,
          mono = m["mono"] as? Boolean ?: d.mono,
          clearSpeech = m["clearSpeech"] as? Boolean ?: d.clearSpeech,
      )
    }
  }
}

data class Words(
    /** "post" -> "open the mail reader". Keys are normalised phrases. Insertion order kept. */
    val aliases: Map<String, String> = emptyMap(),
    /** "morning post" -> ["open mail", "read it all"]. */
    val macros: Map<String, List<String>> = emptyMap(),
    /** Tool ids in the order the home menu says them. */
    val menuOrder: List<String> = DEFAULT_MENU,
    /** Tool ids the home menu doesn't list (they still open by voice). */
    val menuHidden: List<String> = emptyList(),
    /** An extra name the app answers to ("Sam, read my mail"), null = only the built-in ones. */
    val address: String? = null,
) {
  /** The menu as it should be spoken: known tools only, every tool once, hidden ones left out. */
  fun visibleMenu(): List<String> = normalisedOrder().filter { it !in menuHidden }

  fun normalisedOrder(): List<String> {
    val known = menuOrder.filter { it in DEFAULT_MENU }.distinct()
    return known + DEFAULT_MENU.filter { it !in known }
  }

  fun toMap(): Map<String, Any?> =
      linkedMapOf(
          "aliases" to LinkedHashMap(aliases),
          "macros" to LinkedHashMap(macros),
          "menuOrder" to normalisedOrder(),
          "menuHidden" to menuHidden.distinct(),
          "address" to address,
      )

  companion object {
    val DEFAULT_MENU = listOf("book", "mail", "labels", "watch", "light")
    const val MAX_ALIASES = 50
    const val MAX_MACRO_STEPS = 6

    fun fromMap(m: Map<*, *>): Words {
      val d = Words()
      val aliases = linkedMapOf<String, String>()
      (m["aliases"] as? Map<*, *>)?.forEach { (k, v) ->
        if (k is String && v is String && k.isNotBlank() && v.isNotBlank() && aliases.size < MAX_ALIASES) aliases[k] = v
      }
      val macros = linkedMapOf<String, List<String>>()
      (m["macros"] as? Map<*, *>)?.forEach { (k, v) ->
        val steps = (v as? List<*>)?.filterIsInstance<String>()?.filter { it.isNotBlank() }?.take(MAX_MACRO_STEPS)
        if (k is String && k.isNotBlank() && !steps.isNullOrEmpty() && macros.size < MAX_ALIASES) macros[k] = steps
      }
      return Words(
          aliases = aliases,
          macros = macros,
          menuOrder = (m["menuOrder"] as? List<*>)?.filterIsInstance<String>()?.let { Words(menuOrder = it).normalisedOrder() } ?: d.menuOrder,
          menuHidden = (m["menuHidden"] as? List<*>)?.filterIsInstance<String>()?.filter { it in DEFAULT_MENU }?.distinct() ?: d.menuHidden,
          address = (m["address"] as? String)?.trim()?.lowercase(Locale.ROOT)?.takeIf { it.isNotBlank() },
      )
    }
  }
}

/** Glasses buttons and swipes, each mapped to a spoken command (any phrase the app understands). */
data class Controls(
    val enabled: Boolean = false,
    val map: Map<String, String> = DEFAULT_MAP,
) {
  fun actionFor(event: String): String? = (map[event] ?: DEFAULT_MAP[event])?.takeIf { it.isNotBlank() }

  fun toMap(): Map<String, Any?> =
      linkedMapOf<String, Any?>("enabled" to enabled).apply { EVENTS.forEach { put(it, map[it] ?: "") } }

  companion object {
    /** Event keys, in the order "what do my buttons do?" reads them. */
    val EVENTS = listOf("captureShort", "captureHold", "captureDouble", "select", "navUp", "navDown", "navLeft", "navRight", "action")
    val DEFAULT_MAP =
        linkedMapOf(
            "captureShort" to "say that again",
            "captureHold" to "carry on",
            "captureDouble" to "main menu",
            "select" to "stop",
            "navUp" to "faster",
            "navDown" to "slower",
            "navLeft" to "",
            "navRight" to "",
            "action" to "",
        )
    val SPOKEN_EVENT =
        mapOf(
            "captureShort" to "A short press of the capture button",
            "captureHold" to "Holding the capture button",
            "captureDouble" to "A double press of the capture button",
            "select" to "A tap on the touchpad",
            "navUp" to "Swiping forward",
            "navDown" to "Swiping back",
            "navLeft" to "Swiping left",
            "navRight" to "Swiping right",
            "action" to "The action button",
        )

    fun fromMap(m: Map<*, *>): Controls {
      val map = LinkedHashMap(DEFAULT_MAP)
      EVENTS.forEach { e -> (m[e] as? String)?.let { map[e] = it.trim() } }
      return Controls(enabled = m["enabled"] as? Boolean ?: false, map = map)
    }
  }
}

data class Tips(val pacing: Pacing = Pacing.NORMAL) {
  fun toMap(): Map<String, Any?> = linkedMapOf("pacing" to pacing.id)

  /** Silence-reminder gaps for this pacing (IdleNudge), empty for off. */
  fun reminderGapsMs(): List<Long> =
      when (pacing) {
        Pacing.NORMAL -> listOf(30_000L, 60_000L, 120_000L)
        Pacing.FEWER -> listOf(60_000L, 180_000L)
        Pacing.OFF -> emptyList()
      }

  companion object {
    fun fromMap(m: Map<*, *>): Tips = Tips(Pacing.fromId(m["pacing"]) ?: Pacing.NORMAL)
  }
}

/**
 * How descriptions are worded (C6). Stored and exported for iOS parity; Android has no
 * describe-the-scene tool yet. "Say how sure" and the refusal rules are not settings.
 */
data class Descriptions(
    val detail: Verbosity = Verbosity.NORMAL,
    val textFirst: Boolean = true,
    val colours: Boolean = true,
    /** "leftRight" or "clock". */
    val directions: String = "leftRight",
) {
  fun toMap(): Map<String, Any?> =
      linkedMapOf("detail" to detail.id, "textFirst" to textFirst, "colours" to colours, "directions" to directions)

  companion object {
    fun fromMap(m: Map<*, *>): Descriptions {
      val d = Descriptions()
      return Descriptions(
          detail = Verbosity.fromId(m["detail"]) ?: d.detail,
          textFirst = m["textFirst"] as? Boolean ?: d.textFirst,
          colours = m["colours"] as? Boolean ?: d.colours,
          directions = (m["directions"] as? String)?.takeIf { it == "leftRight" || it == "clock" } ?: d.directions,
      )
    }
  }
}

/** Everything, one value. Immutable: a change makes a new Setup, which is what undo keeps. */
data class Setup(
    val speech: Speech = Speech(),
    val sounds: Sounds = Sounds(),
    val ears: Ears = Ears(),
    val words: Words = Words(),
    val controls: Controls = Controls(),
    val tips: Tips = Tips(),
    val descriptions: Descriptions = Descriptions(),
) {
  fun area(a: Area): Map<String, Any?> =
      when (a) {
        Area.SPEECH -> speech.toMap()
        Area.SOUNDS -> sounds.toMap()
        Area.EARS -> ears.toMap()
        Area.WORDS -> words.toMap()
        Area.CONTROLS -> controls.toMap()
        Area.TIPS -> tips.toMap()
        Area.DESCRIPTIONS -> descriptions.toMap()
      }

  /** [m] read into area [a]; missing fields take defaults. */
  fun withArea(a: Area, m: Map<*, *>): Setup =
      when (a) {
        Area.SPEECH -> copy(speech = Speech.fromMap(m))
        Area.SOUNDS -> copy(sounds = Sounds.fromMap(m))
        Area.EARS -> copy(ears = Ears.fromMap(m))
        Area.WORDS -> copy(words = Words.fromMap(m))
        Area.CONTROLS -> copy(controls = Controls.fromMap(m))
        Area.TIPS -> copy(tips = Tips.fromMap(m))
        Area.DESCRIPTIONS -> copy(descriptions = Descriptions.fromMap(m))
      }

  /** Area [a] copied from [other]. */
  fun withAreaFrom(a: Area, other: Setup): Setup =
      when (a) {
        Area.SPEECH -> copy(speech = other.speech)
        Area.SOUNDS -> copy(sounds = other.sounds)
        Area.EARS -> copy(ears = other.ears)
        Area.WORDS -> copy(words = other.words)
        Area.CONTROLS -> copy(controls = other.controls)
        Area.TIPS -> copy(tips = other.tips)
        Area.DESCRIPTIONS -> copy(descriptions = other.descriptions)
      }

  fun differsIn(a: Area, other: Setup): Boolean = area(a) != other.area(a)

  /** {"speech": {...}, ...}, every field. */
  fun areasMap(): Map<String, Any?> = linkedMapOf<String, Any?>().apply { Area.entries.forEach { put(it.id, area(it)) } }

  /** Only what differs from the defaults (for short codes and profiles). */
  fun sparseAreas(areas: List<Area> = Area.entries): Map<String, Any?> {
    val d = Setup()
    return linkedMapOf<String, Any?>().apply {
      for (a in areas) {
        val diff = sparse(area(a), d.area(a))
        if (diff.isNotEmpty()) put(a.id, diff)
      }
    }
  }

  // Effective values the app reads.

  fun rateFor(tool: String?): Float = speech.rateFor(tool).let { if (ears.clearSpeech) it.coerceAtMost(1f) else it }

  fun verbosityFor(tool: String?): Verbosity = speech.verbosityFor(tool)

  val bookPageNumbers: Boolean
    get() = speech.tool("book").pageNumbers ?: false

  val bookAutoTurn: Boolean
    get() = speech.tool("book").autoTurn ?: true

  companion object {
    /** Reads an "areas" object; unknown areas and fields ignored, missing ones default. */
    fun fromAreas(m: Map<*, *>?, base: Setup = Setup()): Setup {
      var s = base
      if (m == null) return s
      for (a in Area.entries) (m[a.id] as? Map<*, *>)?.let { s = s.withArea(a, it) }
      return s
    }

    /** Recursively, the entries of [full] that differ from [defaults]. */
    fun sparse(full: Map<String, Any?>, defaults: Map<String, Any?>): Map<String, Any?> {
      val out = linkedMapOf<String, Any?>()
      for ((k, v) in full) {
        val d = defaults[k]
        if (v is Map<*, *> && d is Map<*, *>) {
          @Suppress("UNCHECKED_CAST")
          val inner = sparse(v as Map<String, Any?>, d as Map<String, Any?>)
          if (inner.isNotEmpty()) out[k] = if (k == "tools" || k == "aliases" || k == "macros") v else inner
        } else if (v != d) {
          out[k] = v
        }
      }
      return out
    }
  }
}

internal fun num(v: Any?): Float? = (v as? Number)?.toFloat()?.takeIf { !it.isNaN() && !it.isInfinite() }

internal fun round2(v: Float): Float = Math.round(v * 100f) / 100f
