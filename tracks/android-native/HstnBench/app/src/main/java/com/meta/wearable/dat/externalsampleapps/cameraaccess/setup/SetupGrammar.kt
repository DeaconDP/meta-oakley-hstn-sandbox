// SetupGrammar - what a user can say on the setup screen (app not yet connected to Meta AI)
//
// The setup screen is the first thing a blind user meets, before any tool or ToolHub exists, so it
// has its own tiny grammar: connect, help, repeat, open settings, quit, and "no / not now". It works
// on the same normalised text as every other grammar (tools/core/Phrases). Negation is checked
// before the command words so "don't connect" never opens Meta AI, and the connect words only
// count in short utterances so room chatter ("I'll start dinner in a minute") doesn't either.
// Pure Kotlin, JVM-tested (SetupGrammarTest).

package com.meta.wearable.dat.externalsampleapps.cameraaccess.setup

import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.Phrases

enum class SetupCommand {
  /** Start registration: speak the handoff, then open Meta AI. */
  CONNECT,
  HELP,
  REPEAT,
  /** Open this app's page in Android Settings (permissions). */
  OPEN_SETTINGS,
  /** Leave the app (moved to the background). */
  QUIT,
  /** "No", "not now", "don't connect". */
  DECLINE,
}

object SetupGrammar {

  /** Commands (other than a "no") only count in utterances up to this long: longer is chatter. */
  const val MAX_COMMAND_WORDS = 7

  private const val NEGATION = "(?:don't|dont|do not|not|never|no|nope|cancel)"
  private const val CONNECT_WORDS =
      "(?:connect|set up|setup|set it up|set me up|register|pair|link|get started|start|begin)"

  private const val QUIT_WORDS =
      "(?:quit|exit|close(?: the| this)?(?: app)?|goodbye|bye|leave(?: the app)?|i'm done|im done)"
  private val QUIT = Regex("\\b$QUIT_WORDS\\b")
  private val NEGATED_QUIT = Regex("(?:^| )$NEGATION(?: \\S+){0,2} $QUIT_WORDS\\b")
  private val NEGATED_CONNECT = Regex("(?:^| )$NEGATION(?: \\S+){0,3} $CONNECT_WORDS\\b")
  private val PLAIN_NO =
      // "now" and "just" are fillers (Phrases), so "not now" arrives as "not".
      Regex("^(?:no|nope|no no|not|not now|not yet|later|maybe later|cancel|never mind|nevermind|wait|hold on|not today)$")
  private val REPEAT =
      Regex("\\b(?:repeat|say (?:that|it) again|again|pardon|what did you say|come again|sorry what|didn't catch that)\\b")
  private val TRY_AGAIN = Regex("\\b(?:try (?:it |that )?again|retry|one more time)\\b")
  private val SETTINGS =Regex("\\b(?:settings|permissions?)\\b")
  private val CONNECT = Regex("\\b$CONNECT_WORDS\\b")
  private val YES = Regex("^(?:yes|yeah|yep|yup|sure|go ahead|let's go|lets go|do it)\\b")
  private val HELP =
      Regex(
          "\\b(?:help|what can i say|what do i say|what should i say|what are my options|options|commands|" +
              "what is this|what's this|where am i|what now|what do i do|how does this work|what do you do)\\b",
      )

  /** The command in [transcript] (raw recogniser text), or null if it isn't one. */
  fun parse(transcript: String): SetupCommand? {
    val t = Phrases.normalize(transcript)
    if (t.isEmpty()) return null
    val words = Phrases.wordCount(t)
    // "Don't close", "no, don't connect": a negated command is a "no".
    if (NEGATED_CONNECT.containsMatchIn(t)) return SetupCommand.DECLINE
    if (NEGATED_QUIT.containsMatchIn(t)) return SetupCommand.DECLINE
    if (words <= MAX_COMMAND_WORDS && QUIT.containsMatchIn(t)) return SetupCommand.QUIT
    if (PLAIN_NO.matches(t)) return SetupCommand.DECLINE
    // "Try again" answers "say connect to try again"; it isn't "repeat".
    if (words <= MAX_COMMAND_WORDS && TRY_AGAIN.containsMatchIn(t)) return SetupCommand.CONNECT
    if (words <= MAX_COMMAND_WORDS && REPEAT.containsMatchIn(t)) return SetupCommand.REPEAT
    if (SETTINGS.containsMatchIn(t) && words <= MAX_COMMAND_WORDS) return SetupCommand.OPEN_SETTINGS
    if (words <= MAX_COMMAND_WORDS && (CONNECT.containsMatchIn(t) || YES.containsMatchIn(t))) {
      return SetupCommand.CONNECT
    }
    if (words <= MAX_COMMAND_WORDS && HELP.containsMatchIn(t)) return SetupCommand.HELP
    return null
  }
}
