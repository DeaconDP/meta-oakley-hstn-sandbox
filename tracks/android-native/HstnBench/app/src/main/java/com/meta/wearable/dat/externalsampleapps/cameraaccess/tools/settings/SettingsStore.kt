// SettingsStore - the one place settings live, with "keep that", undo, lock, profiles and sharing
//
// Two copies of the setup:
//   current  what the app uses right now;
//   saved    what survives a restart.
// A voice tweak ("slower", "shorter", "try another voice") changes only [current]: it's for this
// session until the user says "keep that" (design rule 1). Deliberate changes (a shortcut, a profile
// switch, a reset, an import, anything on the settings screen) change both. Every change is put in
// the journal first, so "undo" can always put it back, including a reset (rule 4). While locked,
// nothing changes except "unlock settings" (rule 5).
//
// Profiles hold the speech, sounds, ears, tips and descriptions areas (only what differs from the
// defaults); words and controls are yours in every profile. Keeping a change also saves it into
// the active profile.
//
// Storage is one JSON document (SetupJson) behind [SetupStorage]; SettingsPrefs puts it in
// SharedPreferences. The first load migrates the old per-tool preference keys ([OldPrefs]).
// Not thread-safe: main thread only. Pure Kotlin, JVM-tested.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings

interface SetupStorage {
  fun read(): String?

  fun write(json: String)
}

class MemoryStorage(var text: String? = null) : SetupStorage {
  override fun read(): String? = text

  override fun write(json: String) {
    text = json
  }
}

/** The values the app kept before the settings store (three SharedPreferences files). */
data class OldPrefs(
    /** tools / speech_rate: the shared tools rate. */
    val toolsRate: Float? = null,
    /** book_reader / speech_rate. */
    val bookRate: Float? = null,
    /** book_reader / read_furniture. */
    val pageNumbers: Boolean? = null,
    /** book_reader / auto_turn. */
    val autoTurn: Boolean? = null,
    /** tools / watch_tick_seconds. */
    val watchTickSeconds: Int? = null,
    /** mode / verbosity (hands-free "short answers"): SHORT, NORMAL or DETAILED. */
    val verbosity: String? = null,
) {
  /** The same values in the new shape: main rate + book override. */
  fun toSetup(): Setup {
    val main = toolsRate?.let { Speech.clampRate(it) } ?: 1f
    var speech = Speech(rate = main)
    val book = bookRate?.let { Speech.clampRate(it) }
    if (book != null && book != main) speech = speech.withTool("book") { it.copy(rate = book) }
    if (pageNumbers == true) speech = speech.withTool("book") { it.copy(pageNumbers = true) }
    if (autoTurn == false) speech = speech.withTool("book") { it.copy(autoTurn = false) }
    verbosity?.let { v -> Verbosity.entries.firstOrNull { it.name == v }?.let { speech = speech.copy(verbosity = it) } }
    val sounds = Sounds(watchTickSeconds = watchTickSeconds?.coerceIn(0, 600) ?: Sounds.DEFAULT_WATCH_TICK_S)
    return Setup(speech = speech, sounds = sounds)
  }
}

class SettingsStore(
    private val storage: SetupStorage,
    oldPrefs: () -> OldPrefs? = { null },
) {
  sealed interface Outcome {
    /** Applied; [spoken] is the new value ("Speed 1.2 times."). */
    data class Changed(val spoken: String) : Outcome

    /** Locked: nothing changed. */
    data object Locked : Outcome

    /** Already like that; [spoken] says so. */
    data class Unchanged(val spoken: String) : Outcome
  }

  private data class Entry(
      val before: Setup,
      val beforeSaved: Setup,
      val beforeProfiles: Map<String, Map<String, Any?>>,
      val beforeActive: String,
      val description: String,
  )

  var current: Setup = Setup()
    private set

  var saved: Setup = Setup()
    private set

  private val profileMap = linkedMapOf<String, Map<String, Any?>>()

  val profiles: Map<String, Map<String, Any?>>
    get() = profileMap

  var activeProfile: String = HOME
    private set

  var locked: Boolean = false
    private set

  /** True if the first load came from the old preference keys. */
  var migrated: Boolean = false
    private set

  private val journal = ArrayDeque<Entry>()
  private val learnCounts = linkedMapOf<String, Int>()
  private val declined = linkedSetOf<String>()

  /** A learned suggestion is waiting for "yes" or "no" (its kind, e.g. "slower"). */
  var pendingSuggestion: String? = null
    private set

  private val listeners = mutableListOf<(Setup) -> Unit>()

  init {
    load(oldPrefs)
  }

  // MARK: reading

  /** Voice tweaks not kept yet. */
  val hasUnkept: Boolean
    get() = current != saved

  /** Areas with tweaks not kept yet. */
  fun unkeptAreas(): List<Area> = Area.entries.filter { current.differsIn(it, saved) }

  val canUndo: Boolean
    get() = journal.isNotEmpty()

  /** The description of the change "undo" would put back. */
  val lastChange: String?
    get() = journal.lastOrNull()?.description

  /** Called with the new setup after every change (current or saved). */
  fun addListener(l: (Setup) -> Unit) {
    listeners += l
  }

  fun removeListener(l: (Setup) -> Unit) {
    listeners -= l
  }

  // MARK: changing

  /**
   * Applies [f]. [keep] = false: this session only, until "keep that". [keep] = true: saved now
   * too ([f] is applied to the saved setup separately, so unkept tweaks stay unkept). [spoken]
   * describes the new value and goes into the journal for undo.
   */
  fun change(spoken: String, keep: Boolean = false, f: (Setup) -> Setup): Outcome {
    if (locked) return Outcome.Locked
    val next = f(current)
    val nextSaved = if (keep) f(saved) else saved
    if (next == current && nextSaved == saved) return Outcome.Unchanged(spoken)
    record(spoken)
    current = next
    if (keep) {
      saved = nextSaved
      profileMap[activeProfile] = nextSaved.sparseAreas(Area.PROFILE_AREAS)
      persist()
    }
    notifyListeners()
    return Outcome.Changed(spoken)
  }

  /** "Keep that": everything tweaked this session is saved (and into the active profile). */
  fun keep(): Outcome {
    if (locked) return Outcome.Locked
    if (!hasUnkept) return Outcome.Unchanged("Nothing new to keep.")
    val areas = unkeptAreas()
    record("keeping " + SetupSpeech.list(areas.map { it.spoken }))
    saved = current
    profileMap[activeProfile] = current.sparseAreas(Area.PROFILE_AREAS)
    pendingSuggestion = null
    learnCounts.clear()
    persist()
    notifyListeners()
    return Outcome.Changed("Kept. " + SetupSpeech.sentence(SetupSpeech.list(areas.flatMap { SetupSpeech.area(it, current) }.ifEmpty { listOf("back to the defaults") })))
  }

  /** "Undo" / "put it back": the last change is reversed. Returns what was undone, or null. */
  fun undo(): Outcome {
    if (locked) return Outcome.Locked
    val e = journal.removeLastOrNull() ?: return Outcome.Unchanged("Nothing to undo.")
    val savedChanged = saved != e.beforeSaved || profileMap != e.beforeProfiles || activeProfile != e.beforeActive
    current = e.before
    saved = e.beforeSaved
    profileMap.clear()
    profileMap.putAll(e.beforeProfiles)
    activeProfile = e.beforeActive
    if (savedChanged) persist()
    notifyListeners()
    return Outcome.Changed("Put back: ${e.description}.")
  }

  /** "Reset speech": the area goes back to its defaults (saved now; undo brings it back). */
  fun reset(area: Area): Outcome =
      change("${area.spoken} back to the defaults", keep = true) { it.withAreaFrom(area, Setup()) }

  /** "Reset everything", except the lock. Undo brings it all back. */
  fun resetAll(): Outcome = change("everything back to the defaults", keep = true) { Setup() }

  fun lock(): Outcome {
    if (locked) return Outcome.Unchanged("Settings are already locked.")
    locked = true
    persist()
    notifyListeners()
    return Outcome.Changed("Settings locked. Say unlock settings to change them again.")
  }

  fun unlock(): Outcome {
    if (!locked) return Outcome.Unchanged("Settings aren't locked.")
    locked = false
    persist()
    notifyListeners()
    return Outcome.Changed("Settings unlocked.")
  }

  // MARK: profiles

  fun hasProfile(name: String): Boolean = profileMap.containsKey(name.lowercase())

  /** The setup [name] would give: its areas over the defaults, words and controls as now. */
  fun setupFor(name: String, base: Setup = current): Setup {
    val overlay = profileMap[name.lowercase()] ?: emptyMap()
    var s = base
    for (a in Area.PROFILE_AREAS) {
      s = s.withArea(a, overlay[a.id] as? Map<*, *> ?: emptyMap<String, Any?>())
    }
    return s
  }

  /** "Switch to out and about": a manual choice, saved, announced, undoable. */
  fun switchProfile(name: String): Outcome {
    val key = name.lowercase().trim()
    if (!profileMap.containsKey(key)) return Outcome.Unchanged("There's no profile called $key. " + listProfilesLine())
    if (locked) return Outcome.Locked
    if (key == activeProfile && !hasUnkept) return Outcome.Unchanged("You're already on $key.")
    record("profile $activeProfile")
    activeProfile = key
    current = setupFor(key, current)
    // Unkept tweaks are dropped with the old profile; words and controls carry over.
    saved = current
    persist()
    notifyListeners()
    val diff = Area.PROFILE_AREAS.flatMap { SetupSpeech.area(it, current) }
    return Outcome.Changed("Switched to $key." + if (diff.isEmpty()) "" else " " + SetupSpeech.sentence(SetupSpeech.list(diff)))
  }

  /** "Save this as reading": the current speech, sounds, ears, tips and descriptions, kept too. */
  fun saveProfile(name: String): Outcome {
    val key = name.lowercase().trim().take(40)
    if (key.isEmpty()) return Outcome.Unchanged("What should the profile be called?")
    if (locked) return Outcome.Locked
    record("profile ${activeProfile}" + if (profileMap.containsKey(key)) "" else ", before $key was saved")
    profileMap[key] = current.sparseAreas(Area.PROFILE_AREAS)
    activeProfile = key
    saved = current
    persist()
    notifyListeners()
    return Outcome.Changed("Saved as $key. You're on $key now.")
  }

  fun deleteProfile(name: String): Outcome {
    val key = name.lowercase().trim()
    if (!profileMap.containsKey(key)) return Outcome.Unchanged("There's no profile called $key.")
    if (key == HOME) return Outcome.Unchanged("Home can't be deleted.")
    if (locked) return Outcome.Locked
    record("profile $key deleted")
    profileMap.remove(key)
    if (activeProfile == key) {
      activeProfile = HOME
      current = setupFor(HOME, current)
      saved = current
    }
    persist()
    notifyListeners()
    return Outcome.Changed("Deleted $key. You're on $activeProfile.")
  }

  fun listProfilesLine(): String = "Your profiles are " + SetupSpeech.list(profileMap.keys.toList()) + "."

  // MARK: learned suggestions (rule 9: ask, never apply silently)

  /**
   * A voice tweak of [kind] ("slower", "shorter") happened. After the third one (across sessions,
   * until kept), returns a question for the user; the answer comes back through [answerSuggestion].
   */
  fun noteTweak(kind: String): String? {
    if (kind in declined) return null
    val n = (learnCounts[kind] ?: 0) + 1
    learnCounts[kind] = n
    persistDevice()
    if (n < LEARN_AFTER || !hasUnkept) return null
    learnCounts[kind] = 0
    pendingSuggestion = kind
    return "You've said $kind $n times. Make this your default for $activeProfile? Say yes or no."
  }

  fun answerSuggestion(yes: Boolean): Outcome {
    val kind = pendingSuggestion ?: return Outcome.Unchanged("")
    pendingSuggestion = null
    if (yes) return keep()
    declined += kind
    persistDevice()
    return Outcome.Changed("OK, I won't ask about that again. It stays for this session only.")
  }

  fun dropSuggestion() {
    pendingSuggestion = null
  }

  // MARK: export and import

  /** The whole setup as shared JSON (no device-only fields). */
  fun exportJson(): String = SetupJson.encode(fileMap(sparse = false, device = false))

  /** A short code: only what differs from the defaults, compressed. */
  fun exportCode(): String = SetupJson.toCode(SetupJson.encode(fileMap(sparse = true, device = false)))

  /** A pasted code or JSON. Replaces areas (and profiles, if it has them). Saved; undoable. */
  fun import(text: String): Outcome {
    if (locked) return Outcome.Locked
    val json = SetupJson.fromCode(text) ?: text
    val root = SetupJson.parse(json) as? Map<*, *> ?: return Outcome.Unchanged("That isn't a SpeakUp setup.")
    val schema = (root["schema"] as? Number)?.toInt() ?: SetupJson.SCHEMA
    if (schema > SetupJson.SCHEMA) return Outcome.Unchanged("That setup is from a newer SpeakUp. Update the app first.")
    val areas = root["areas"] as? Map<*, *> ?: root.takeIf { r -> r.keys.any { Area.fromId(it as? String) != null } }
    ?: return Outcome.Unchanged("That isn't a SpeakUp setup.")
    val imported = Setup.fromAreas(areas)
    val newProfiles = readProfiles(root["profiles"])
    record("the setup before the import")
    current = imported
    saved = imported
    if (newProfiles != null) {
      profileMap.clear()
      profileMap.putAll(STARTERS)
      profileMap.putAll(newProfiles)
      if (HOME !in profileMap) profileMap[HOME] = emptyMap()
    }
    val active = (root["activeProfile"] as? String)?.lowercase()
    activeProfile = if (active != null && profileMap.containsKey(active)) active else if (profileMap.containsKey(activeProfile)) activeProfile else HOME
    profileMap[activeProfile] = imported.sparseAreas(Area.PROFILE_AREAS)
    persist()
    notifyListeners()
    val diff = SetupSpeech.differences(imported)
    return Outcome.Changed("Setup imported." + if (diff.isEmpty()) " Everything is at the defaults." else " " + SetupSpeech.sentence(SetupSpeech.list(diff)))
  }

  // MARK: storage

  private fun record(description: String) {
    journal.addLast(Entry(current, saved, LinkedHashMap(profileMap), activeProfile, description))
    while (journal.size > JOURNAL_SIZE) journal.removeFirst()
  }

  private fun notifyListeners() {
    val s = current
    listeners.toList().forEach { it(s) }
  }

  private fun fileMap(sparse: Boolean, device: Boolean): Map<String, Any?> =
      linkedMapOf<String, Any?>(
          "schema" to SetupJson.SCHEMA.toLong(),
          "areas" to if (sparse) saved.sparseAreas() else saved.areasMap(),
          // The short code leaves out starter profiles nobody changed; import adds them back.
          "profiles" to if (sparse) profileMap.filter { (k, v) -> STARTERS[k] != v } else LinkedHashMap(profileMap),
          "activeProfile" to activeProfile,
      ).apply {
        if (device) {
          put(
              "device",
              linkedMapOf(
                  "locked" to locked,
                  "learn" to learnCounts.mapValues { it.value.toLong() },
                  "declined" to declined.toList(),
                  "migratedFrom" to if (migrated) "prefs" else null,
              ),
          )
        }
      }

  private fun persist() = storage.write(SetupJson.encode(fileMap(sparse = false, device = true)))

  private fun persistDevice() = persist()

  private fun load(oldPrefs: () -> OldPrefs?) {
    val root = storage.read()?.let { SetupJson.parse(it) as? Map<*, *> }
    if (root == null) {
      val old = oldPrefs()
      saved = old?.toSetup() ?: Setup()
      migrated = old != null
      profileMap.putAll(STARTERS)
      profileMap[HOME] = saved.sparseAreas(Area.PROFILE_AREAS)
      activeProfile = HOME
      current = saved
      persist()
      return
    }
    saved = Setup.fromAreas(root["areas"] as? Map<*, *>)
    current = saved
    profileMap.putAll(readProfiles(root["profiles"]) ?: STARTERS)
    if (HOME !in profileMap) profileMap[HOME] = emptyMap()
    activeProfile = (root["activeProfile"] as? String)?.takeIf { profileMap.containsKey(it) } ?: HOME
    (root["device"] as? Map<*, *>)?.let { d ->
      locked = d["locked"] as? Boolean ?: false
      (d["learn"] as? Map<*, *>)?.forEach { (k, v) -> if (k is String && v is Number) learnCounts[k] = v.toInt() }
      (d["declined"] as? List<*>)?.filterIsInstance<String>()?.let { declined += it }
      migrated = d["migratedFrom"] == "prefs"
    }
  }

  private fun readProfiles(v: Any?): Map<String, Map<String, Any?>>? {
    val m = v as? Map<*, *> ?: return null
    val out = linkedMapOf<String, Map<String, Any?>>()
    for ((k, p) in m) {
      val name = (k as? String)?.lowercase()?.trim()?.takeIf { it.isNotEmpty() } ?: continue
      val areas = p as? Map<*, *> ?: continue
      // Normalised through the area readers, then sparse again: unknown fields don't survive.
      val s = Setup.fromAreas(areas)
      out[name] = s.sparseAreas(Area.PROFILE_AREAS)
      if (out.size >= MAX_PROFILES) break
    }
    return out
  }

  companion object {
    const val HOME = "home"
    const val OUT = "out and about"
    const val READING = "reading"
    const val JOURNAL_SIZE = 30
    const val LEARN_AFTER = 3
    const val MAX_PROFILES = 12

    /** The starter profiles: Home (defaults), Out and about (terse, sounds first), Reading. */
    val STARTERS: Map<String, Map<String, Any?>> =
        linkedMapOf(
            HOME to emptyMap(),
            OUT to
                Setup(
                        speech = Speech(preset = Preset.BRISK, rate = Preset.BRISK.rate, verbosity = Verbosity.SHORT),
                        sounds = Sounds(earconsOnly = true),
                        tips = Tips(Pacing.FEWER),
                    )
                    .sparseAreas(Area.PROFILE_AREAS),
            READING to
                Setup(
                        speech = Speech(pauseMs = 250).withTool("book") { it.copy(verbosity = Verbosity.DETAILED) },
                        tips = Tips(Pacing.FEWER),
                    )
                    .sparseAreas(Area.PROFILE_AREAS),
        )
  }
}
