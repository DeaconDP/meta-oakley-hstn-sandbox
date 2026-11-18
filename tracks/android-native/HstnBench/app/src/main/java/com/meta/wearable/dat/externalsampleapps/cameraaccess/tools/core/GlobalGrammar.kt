// GlobalGrammar - what the user can say in every tool
//
// Each tool has its own grammar for its own commands (book/VoiceCommands, tools/mail/MailGrammar,
// ...). ToolHub tries the open tool's grammar first and this one second, so a tool can give a
// phrase its own meaning ("read" in the book reader). This file covers three things:
//
//  1. Opening another tool from inside any tool: "read my mail", "what is this letter" -> mail;
//     "watch for 42", "tell me when you see exit" -> watch (target "42" / "exit"); "scan this",
//     "what's this product", "read the label" -> labels; "light detector", "is the light on" ->
//     light; "what colour is this" -> light in colour mode; "open the book reader", "read a book"
//     -> book. Each tool's own phrases live in its grammar file (MailGrammar.opens, ...), so a
//     feature agent can add synonyms without touching this file. They're tried in [OPENERS] order.
//  2. Questions about text that was just read ("what does ephemeral mean", "who is Mr. Bennet",
//     "what happened last time"), parsed by tools/ask/AskGrammar and answered by AskAboutText.
//  3. Commands every tool understands: pause/stop, carry on, repeat, faster/slower/speed, help,
//     battery, close, "main menu" (back to the home voice menu) and "close the app" (leave the app).
//  4. Hands-free mode (notes/hands-free-mode.md): "hands-free on/off" (also "voice mode", "touch
//     mode", "stop listening for good"), "what tools are there", "where am I", "back", "connect",
//     "disconnect", "status", "settings", "short/normal/detailed answers", "glasses display on/off".
//     Tool grammars still run first, so the book reader keeps its own "where am I", "back", "status".
//
// [parseHome] is what the home voice menu (CameraScreen with no tool open) understands: everything
// here plus bare tool names ("light", "book", "colour"), which are too short to be safe inside a
// tool but are the natural answer to "Say read my book, read my mail, labels, ... or light".
//
// Same style as the book reader's grammar: ordered regex rules over normalised text (Phrases),
// fillers dropped, and room chatter parses to nothing. Pure Kotlin, JVM-tested (GlobalGrammarTest).

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core

import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ask.AskGrammar
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.labels.LabelsGrammar
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.light.LightGrammar
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.mail.MailGrammar
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.watch.WatchGrammar

sealed interface GlobalCommand {
  /** Stop talking now; the tool keeps its place. */
  data object Pause : GlobalCommand

  /** Carry on after a pause. */
  data object Resume : GlobalCommand

  /** Say the last thing again. */
  data object Repeat : GlobalCommand

  data class Faster(val step: Float = STEP) : GlobalCommand

  data class Slower(val step: Float = STEP) : GlobalCommand

  /** Exact speech rate, 1.0 = normal. */
  data class SetRate(val rate: Float) : GlobalCommand

  /** What you can say here. */
  data object Help : GlobalCommand

  /** Glasses and phone battery. */
  data object Battery : GlobalCommand

  /** Leave the tool (in the home menu: leave the app). */
  data object Close : GlobalCommand

  /** "Main menu", "go home": close the tool and go back to the home voice menu (not exit). */
  data object Home : GlobalCommand

  /** "Close the app": end the glasses session and leave the app, from a tool or the menu. */
  data object ExitApp : GlobalCommand

  /** Open another tool (or the same one with a new argument), keeping the glasses session. */
  data class Open(val request: ToolRequest) : GlobalCommand

  /**
   * A question about text that was just read. [question] is what the user said (address and
   * punctuation as heard); [subject] is the word or name asked about, when there is one.
   */
  data class Ask(val question: String, val subject: String? = null) : GlobalCommand

  // Hands-free mode (notes/hands-free-mode.md > What hands-free covers): everything a tap can do.

  /** "What tools are there", "list tools": the tools, by name. */
  data object ListTools : GlobalCommand

  /** "Where am I": the screen or tool, what it's doing, and the glasses connection. */
  data object WhereAmI : GlobalCommand

  /** "Back", "go back": up one level (a tool closes to the menu; in the menu, says where you are). */
  data object Back : GlobalCommand

  /** "Connect", "connect my glasses": bring the session and camera up. */
  data object Connect : GlobalCommand

  /** "Disconnect", "end the session": stop the glasses session (the app stays registered). */
  data object Disconnect : GlobalCommand

  /** "Status": glasses, camera stream and battery. */
  data object Status : GlobalCommand

  /** "Settings": the current speed, answer length, glasses display and mode, spoken. */
  data object Settings : GlobalCommand

  /** "Short answers", "normal answers", "detailed answers". */
  data class SetVerbosity(val verbosity: Verbosity) : GlobalCommand

  /** "Glasses display on/off". */
  data class GlassesDisplay(val on: Boolean) : GlobalCommand

  /** "Hands-free on", "voice mode" / "hands-free off", "touch mode", "stop listening for good". */
  data class HandsFree(val on: Boolean) : GlobalCommand

  companion object {
    const val STEP = 0.25f
    const val BIG_STEP = 0.5f
  }
}

/** One tool's "open me" phrases: normalised text and light text in, a request out. */
typealias ToolOpener = (normalized: String, light: String) -> ToolRequest?

object GlobalGrammar {

  /** Book reader phrases. The other tools' are in their own grammar files. */
  fun bookOpens(normalized: String, @Suppress("UNUSED_PARAMETER") light: String): ToolRequest? =
      if (BOOK_OPEN.matches(normalized)) ToolRequest(ToolId.BOOK) else null

  private val BOOK_OPEN =
      Regex(
          "^(?:(?:open|start|go to|switch to)(?: (?:the|my))? book(?: reader)?|(?:the )?book reader|" +
              "read (?:a|my|the) book|(?:go )?back to (?:the |my )?book|book mode)$",
      )

  /**
   * Tried in this order. Watch comes first because everything after "watch for" is its argument;
   * colour comes before light inside LightGrammar.
   */
  val OPENERS: List<ToolOpener> =
      listOf(
          WatchGrammar::opens,
          MailGrammar::opens,
          LabelsGrammar::opens,
          LightGrammar::opens,
          ::bookOpens,
      )

  private class Rule(pattern: String, val build: (MatchResult) -> GlobalCommand?) {
    val regex = Regex("^(?:$pattern)$")
  }

  private const val NUM = Phrases.NUM

  /** "hands free", "hands-free", "handsfree" (the hyphen is already a space after Phrases.light). */
  private const val HF = "(?:hands ?free|hands free)"

  /** Switching the mode. Kept apart so the setup screen can use them too ([parseMode]). */
  private val MODE_RULES: List<Rule> =
      listOf(
          // Before Pause: "stop listening for good" isn't a pause.
          Rule("(?:$HF (?:off|mode off)|(?:turn|switch) off $HF(?: mode)?|(?:turn|switch) $HF(?: mode)? off|(?:stop|end|exit|leave|quit) $HF(?: mode)?|no more $HF|touch(?: only)? mode|(?:go |switch )?(?:back )?to touch(?: only)?(?: mode)?|stop listening for good|stop listening all the time)") {
            GlobalCommand.HandsFree(false)
          },
          Rule("(?:$HF(?: mode)? on|(?:turn|switch) on $HF(?: mode)?|(?:turn|switch) $HF(?: mode)? on|(?:start|use|go|enter|begin) $HF(?: mode)?|$HF mode|$HF please|voice(?: only)? mode|(?:go |switch )?to voice(?: only)?(?: mode)?|listen all the time|keep listening)") {
            GlobalCommand.HandsFree(true)
          },
      )

  private val HANDS_FREE_RULES: List<Rule> =
      listOf(
          Rule("(?:(?:what|which) tools (?:are there|do (?:you|i) have|have you got|can i use|are available)|(?:list|name|tell me)(?: all)?(?: the| my)? tools|what tools|tools list|list of tools|what can (?:you|this app|it) do|(?:the |my )?tools)") {
            GlobalCommand.ListTools
          },
          Rule("(?:where am i|where are we|what screen is this|which screen is this|what(?:'s| is) open|which tool is (?:this|open)|what tool is (?:this|open)|what am i in)") {
            GlobalCommand.WhereAmI
          },
          Rule("(?:(?:go )?back|go back up|up one level|previous screen)") {
            GlobalCommand.Back
          },
          Rule("(?:(?:re)?connect(?: to)?(?: (?:my|the))?(?: glasses)?|(?:start|begin) (?:the |a )?session|(?:turn|switch) on (?:the |my )?(?:glasses )?camera|(?:start|open) (?:the )?(?:glasses )?camera)") {
            GlobalCommand.Connect
          },
          Rule("(?:disconnect(?: from)?(?: (?:my|the))?(?: glasses)?|(?:end|stop) (?:the |this )?session|(?:turn|switch) off (?:the |my )?(?:glasses )?camera|(?:stop|close) (?:the )?(?:glasses )?(?:camera|stream))") {
            GlobalCommand.Disconnect
          },
          Rule("(?:status|(?:what(?:'s| is)|check) (?:the |my )?(?:status|connection)|connection(?: status)?|(?:are|is) (?:my |the )?glasses connected|am i connected|is it connected|are we connected|how are (?:my |the )?glasses)") {
            GlobalCommand.Status
          },
          Rule("(?:settings|my settings|(?:what are|read) (?:my|the) settings|open (?:the )?settings|show (?:me )?(?:the )?settings)") {
            GlobalCommand.Settings
          },
          Rule("(?:(?:give me |use |make (?:it|them) |make the answers? )?(?:short|shorter|brief|briefer|quick) (?:answers?|replies)(?: please)?|(?:be )?(?:brief|briefer|shorter)|(?:keep it|keep them) short|less detail)") {
            GlobalCommand.SetVerbosity(Verbosity.SHORT)
          },
          Rule("(?:(?:give me |use )?(?:normal|regular|medium|standard) (?:answers?|replies|detail)|normal length)") {
            GlobalCommand.SetVerbosity(Verbosity.NORMAL)
          },
          Rule("(?:(?:give me |use )?(?:detailed|long|longer|full|fuller) (?:answers?|replies)|more detail|(?:tell me )?in detail|be more detailed)") {
            GlobalCommand.SetVerbosity(Verbosity.DETAILED)
          },
          Rule("(?:(?:the )?glasses display off|(?:turn|switch) off (?:the )?glasses display|(?:turn|switch) (?:the )?glasses display off|(?:the )?display off|(?:turn|switch) off the display|(?:stop|don'?t) show(?:ing)? (?:it )?on (?:the |my )?glasses|hide (?:the )?(?:glasses )?display)") {
            GlobalCommand.GlassesDisplay(false)
          },
          Rule("(?:(?:the )?glasses display on|(?:turn|switch) on (?:the )?glasses display|(?:turn|switch) (?:the )?glasses display on|(?:the )?display on|(?:turn|switch) on the display|show (?:it )?on (?:the |my )?glasses|show (?:the )?(?:glasses )?display)") {
            GlobalCommand.GlassesDisplay(true)
          },
      )

  private val RULES: List<Rule> =
      listOf(
          // Before Close, which would take "close the app" as "close this tool".
          Rule("(?:close|exit|quit|leave|shut(?: down)?|end)(?: (?:the|this))? (?:whole )?(?:app|application)|close everything|turn (?:the )?app off") {
            GlobalCommand.ExitApp
          },
          Rule("(?:(?:go |take me )?(?:back )?(?:to )?(?:the )?(?:main )?menu|(?:open|show)(?: me)? (?:the )?(?:main )?menu|main menu please|(?:go |take me )?(?:back )?home|(?:go |take me )?back to (?:the )?home(?: screen)?|home screen)") {
            GlobalCommand.Home
          },
          Rule("(?:close|exit|quit|leave)(?: (?:the|this))?(?: (?:book|reader|book reader|app|tool|mail|mail reader|label reader|labels|light detector|watch|watch for text))?|goodbye|bye|i'?m done(?: here)?|that'?s (?:all|enough)(?: for (?:now|today))?") {
            GlobalCommand.Close
          },
          Rule("(?:(?:set |change )?(?:the )?(?:speed|rate|speech rate) (?:to |at )?$NUM(?: times| x)?|(?:talk |speak |read |go )?(?:at )?$NUM ?(?:times|x)(?: speed)?|$NUM speed)") { m ->
            val raw = m.groupValues.drop(1).firstOrNull { it.isNotEmpty() } ?: return@Rule null
            Phrases.parseNumber(raw)?.let { GlobalCommand.SetRate(it) }
          },
          Rule("(?:(?:back to )?normal speed|(?:reset|normal) (?:the )?(?:speed|rate)|regular speed)") {
            GlobalCommand.SetRate(1f)
          },
          Rule("(?:(?:much|a lot|way) faster|speed up a lot|much quicker)") {
            GlobalCommand.Faster(GlobalCommand.BIG_STEP)
          },
          Rule("(?:(?:much|a lot|way) slower|slow down a lot|much more slowly)") {
            GlobalCommand.Slower(GlobalCommand.BIG_STEP)
          },
          Rule("(?:(?:a )?(?:bit |little |little bit )?(?:faster|quicker)|speed (?:it )?up(?: a bit)?|(?:go|talk|speak|read) faster|hurry(?: up)?|too slow)") {
            GlobalCommand.Faster()
          },
          Rule("(?:(?:a )?(?:bit |little |little bit )?(?:slower|more slowly)|slow (?:it )?down(?: a bit)?|(?:go|talk|speak|read) slower|too fast)") {
            GlobalCommand.Slower()
          },
          Rule("(?:battery|batteries|battery level|how(?:'s| is| are) (?:the |my )?(?:battery|batteries)|how much battery(?: is left| do i have| have i got)?|check (?:the )?battery|is the battery (?:ok|low))") {
            GlobalCommand.Battery
          },
          Rule("(?:help|what can i say|what do i say|what are (?:the|my) (?:commands|options)|commands|options|how does this work)") {
            GlobalCommand.Help
          },
          Rule("(?:repeat(?: that| it)?|say (?:that|it) again|again|once more|pardon(?: me)?|sorry|what\\??|what did (?:it|you|that) say|i didn'?t (?:catch|get|hear) that|come again)") {
            GlobalCommand.Repeat
          },
          Rule("(?:stop|stop (?:it|talking|there)|pause|pause (?:it|there)|wait|wait (?:a (?:sec|second|moment|minute)|there)|(?:hold|hang) on(?: a (?:sec|second|moment|minute))?|hold it|quiet|be quiet|shush|shh+|hush|one (?:sec|second|moment|minute)|(?:just )?a (?:sec|second|moment|minute)|enough)") {
            GlobalCommand.Pause
          },
          Rule("(?:go on|go ahead|carry on|keep going|continue|resume|unpause|start|begin|i'?m ready|ready)") {
            GlobalCommand.Resume
          },
      )

  /** The global command in [transcript], or null if there isn't one. */
  fun parse(transcript: String): GlobalCommand? {
    val text = Phrases.normalize(transcript)
    if (text.isEmpty()) return null
    val light = Phrases.light(transcript).replace(Phrases.ANY_ADDRESS, "").trim()
    for (opener in OPENERS) opener(text, light)?.let { return GlobalCommand.Open(it) }
    // Whole-phrase app commands before questions: "what's the status" isn't a question about a text.
    for (rule in MODE_RULES + HANDS_FREE_RULES) {
      val m = rule.regex.matchEntire(text) ?: continue
      rule.build(m)?.let { return it }
    }
    AskGrammar.parse(text, transcript)?.let { return it }
    for (rule in RULES) {
      val m = rule.regex.matchEntire(text) ?: continue
      rule.build(m)?.let { return it }
    }
    return null
  }

  /** Bare tool names, only in the home menu (inside a tool they'd be too easy to say by accident). */
  private val HOME_NAMES: List<Pair<Regex, ToolRequest>> =
      listOf(
          Regex("^(?:(?:the |my )?books?|reading|book reading)$") to ToolRequest(ToolId.BOOK),
          Regex("^(?:(?:the |my )?(?:letters?|post)|mail reader please)$") to ToolRequest(ToolId.MAIL),
          Regex("^(?:watch|watcher|watch text|text watch|watch for)$") to ToolRequest(ToolId.WATCH),
          Regex("^(?:barcodes?|(?:the )?label reader|scanner|scan)$") to ToolRequest(ToolId.LABELS),
          Regex("^(?:colou?rs?|colou?r mode)$") to ToolRequest(ToolId.LIGHT, mode = ToolRequest.MODE_COLOUR),
          Regex("^(?:(?:the )?lights?|brightness|light level)$") to ToolRequest(ToolId.LIGHT),
      )

  /**
   * What the home voice menu understands: [parse], then bare tool names ("light", "book",
   * "colour"). In the menu Close means leave the app (ToolHub decides; the grammar doesn't).
   */
  fun parseHome(transcript: String): GlobalCommand? {
    parse(transcript)?.let { return it }
    val text = Phrases.normalize(transcript)
    if (text.isEmpty()) return null
    for ((regex, request) in HOME_NAMES) if (regex.matches(text)) return GlobalCommand.Open(request)
    return null
  }

  /**
   * Only the mode switches ("hands-free on", "touch mode"), for screens with their own grammar (the
   * setup screen) that still have to honour them.
   */
  fun parseMode(transcript: String): GlobalCommand.HandsFree? {
    val text = Phrases.normalize(transcript)
    if (text.isEmpty()) return null
    for (rule in MODE_RULES) {
      val m = rule.regex.matchEntire(text) ?: continue
      (rule.build(m) as? GlobalCommand.HandsFree)?.let { return it }
    }
    return null
  }

  /** True if [transcript] is only a stop-talking command, so a tool can act on a partial result. */
  fun isBargeIn(transcript: String): Boolean = parse(transcript) == GlobalCommand.Pause
}
