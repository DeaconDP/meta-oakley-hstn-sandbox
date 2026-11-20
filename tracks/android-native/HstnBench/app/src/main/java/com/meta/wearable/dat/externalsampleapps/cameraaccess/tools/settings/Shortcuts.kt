// Shortcuts - your own words for commands (aliases) and short routines of commands (macros)
//
// "When I say post, open the mail reader" adds an alias; "when I say morning post, open mail and
// read it all" adds a routine (a macro: up to six existing commands, run in order). Before anything
// is parsed, ToolHub rewrites a transcript that is exactly a shortcut ([rewrite]).
//
// Conflict check: a shortcut phrase that already means something (any grammar: global, settings,
// book, mail, watch, labels, light, questions) is refused with the reason. A target nothing
// understands is refused too. Shortcuts can't point at other shortcuts (one rewrite, no loops).
// Pure Kotlin, JVM-tested.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings

import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.VoiceCommands
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ask.AskGrammar
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.GlobalGrammar
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.Phrases
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.labels.LabelsGrammar
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.light.LightGrammar
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.mail.MailGrammar
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.watch.WatchGrammar

/** What the app's grammars make of a phrase. Pure; used for the conflict check. */
object CommandCatalog {

  /** A short description of what [phrase] already does, or null if nothing claims it. */
  fun meaningOf(phrase: String): String? {
    val normalized = Phrases.normalize(phrase)
    if (normalized.isEmpty()) return null
    GlobalGrammar.parse(phrase)?.let { return describe(it.toString()) }
    SettingsGrammar.parse(phrase)?.let { return describe(it.toString()) }
    VoiceCommands.parse(phrase)?.let { return "a book reader command" }
    MailGrammar.parse(normalized)?.let { return "a mail reader command" }
    WatchGrammar.parse(normalized, Phrases.light(phrase))?.let { return "a watch for text command" }
    LabelsGrammar.parse(normalized)?.let { return "a label reader command" }
    LightGrammar.parse(normalized)?.let { return "a light detector command" }
    AskGrammar.parse(normalized, phrase)?.let { return "a question about the text" }
    return null
  }

  /** True if some part of the app understands [command] (home menu names included). */
  fun understands(command: String): Boolean =
      meaningOf(command) != null || GlobalGrammar.parseHome(command) != null

  private fun describe(raw: String): String {
    val name = raw.substringBefore('(').substringAfterLast('.').substringAfterLast('$')
    return "the " + name.replace(Regex("([a-z])([A-Z])"), "$1 $2").lowercase() + " command"
  }
}

object Shortcuts {

  sealed interface Result {
    data class Added(val words: Words, val spoken: String) : Result

    data class Refused(val spoken: String) : Result
  }

  /** What a transcript turns into: one command, or a routine of several. */
  sealed interface Rewrite {
    data class Alias(val phrase: String, val command: String) : Rewrite

    data class Macro(val name: String, val steps: List<String>) : Rewrite
  }

  private val STEP_SPLIT = Regex(",? and then |, then | then |,? and also |, ")
  private val AND_SPLIT = Regex(" and ")

  fun key(phrase: String): String = SettingsGrammar.normalize(phrase)

  fun rewrite(transcript: String, words: Words): Rewrite? {
    val k = key(transcript)
    if (k.isEmpty()) return null
    words.aliases[k]?.let { return Rewrite.Alias(k, it) }
    words.macros[k]?.let { return Rewrite.Macro(k, it) }
    return null
  }

  /** "When I say ...": an alias or a routine, or a spoken reason why not. */
  fun define(
      cmd: SettingsCommand.DefineShortcut,
      words: Words,
      meaningOf: (String) -> String? = CommandCatalog::meaningOf,
      understands: (String) -> Boolean = CommandCatalog::understands,
  ): Result {
    val candidates =
        if (cmd.phrase != null && cmd.target != null) listOf(cmd.phrase to cmd.target)
        else {
          val w = cmd.body.split(' ').filter { it.isNotEmpty() }
          (1..minOf(4, w.size - 1)).map { i -> w.take(i).joinToString(" ") to w.drop(i).joinToString(" ") }
        }
    if (candidates.isEmpty()) return Result.Refused("Say: when I say a word, then the command it should do.")
    var firstProblem: String? = null
    for ((rawPhrase, rawTarget) in candidates) {
      val phrase = key(rawPhrase)
      val target = rawTarget.trim().trimEnd('.', '!', '?')
      if (phrase.isEmpty() || target.isEmpty()) continue
      val steps = steps(target, understands)
      if (steps == null) {
        firstProblem = firstProblem ?: "I don't know how to $target. Say it the way you'd ask me, like open the mail reader."
        continue
      }
      // Found the split that makes sense. Now the checks that refuse it.
      meaningOf(phrase)?.let { return Result.Refused("$phrase already means $it. Pick another word.") }
      if (phrase.split(' ').size > 5) return Result.Refused("$phrase is a bit long. Keep it to a few words.")
      if (steps.any { key(it) in words.aliases || key(it) in words.macros }) {
        return Result.Refused("A shortcut can't use another shortcut. Say the commands themselves.")
      }
      val replacing = phrase in words.aliases || phrase in words.macros
      if (!replacing && words.aliases.size + words.macros.size >= Words.MAX_ALIASES) {
        return Result.Refused("You have ${Words.MAX_ALIASES} shortcuts already. Forget one first.")
      }
      return if (steps.size == 1) {
        val w = words.copy(aliases = LinkedHashMap(words.aliases - phrase).apply { put(phrase, steps[0]) }, macros = words.macros - phrase)
        Result.Added(w, "When you say $phrase, I'll ${steps[0]}.")
      } else {
        val w = words.copy(macros = LinkedHashMap(words.macros - phrase).apply { put(phrase, steps) }, aliases = words.aliases - phrase)
        Result.Added(w, "When you say $phrase, I'll ${readBack(steps)}.")
      }
    }
    return Result.Refused(firstProblem ?: "Say: when I say a word, then the command it should do.")
  }

  /** [target] as one understood command, or several in order, or null. */
  fun steps(target: String, understands: (String) -> Boolean): List<String>? {
    if (understands(target)) return listOf(target)
    for (split in listOf(STEP_SPLIT, AND_SPLIT)) {
      val parts = target.split(split).map { it.trim() }.filter { it.isNotEmpty() }
      if (parts.size in 2..Words.MAX_MACRO_STEPS && parts.all(understands)) return parts
    }
    // "open mail and read it all, then stop": split on both.
    val parts = target.split(STEP_SPLIT).flatMap { it.split(AND_SPLIT) }.map { it.trim() }.filter { it.isNotEmpty() }
    if (parts.size in 2..Words.MAX_MACRO_STEPS && parts.all(understands)) return parts
    return null
  }

  fun readBack(steps: List<String>): String = steps.joinToString(", then ")

  fun forget(phrase: String, words: Words): Result {
    val k = key(phrase)
    return when {
      k in words.aliases -> Result.Added(words.copy(aliases = words.aliases - k), "Forgot $k.")
      k in words.macros -> Result.Added(words.copy(macros = words.macros - k), "Forgot $k.")
      else -> Result.Refused("There's no shortcut called $k." + listLine(words).let { if (it.isEmpty()) "" else " $it" })
    }
  }

  fun listLine(words: Words): String {
    if (words.aliases.isEmpty() && words.macros.isEmpty()) return ""
    val parts =
        words.aliases.map { (k, v) -> "$k: $v" } + words.macros.map { (k, v) -> "$k: ${readBack(v)}" }
    return "Your shortcuts. " + parts.joinToString(". ") + "."
  }
}
