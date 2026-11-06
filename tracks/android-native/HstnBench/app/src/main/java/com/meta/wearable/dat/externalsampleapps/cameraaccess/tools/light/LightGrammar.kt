// LightGrammar - what the user says to and inside the light and colour tool
//
// [opens]: the phrases that open this tool from any tool. "What colour is this" opens it in colour
// mode (ToolRequest.MODE_COLOUR); "light detector", "is the light on" open the light probe.
// GlobalGrammar calls it; add synonyms here, not there. [parse]: commands inside the tool: "how
// bright is it", "where's the light", "is it blinking", "again" (measure again: the global grammar
// would take it as "repeat"), "colour mode" / "what colour is this", "light mode", and "tone off" /
// "tone on" (plain "quiet", "pause", "carry on" are global and the tool handles them in onGlobal).
// ToolHub tries [parse] before the global grammar, so don't claim phrases that open other tools.
// Pure Kotlin (no Android imports), JVM-tested.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.light

import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolRequest

/** Commands inside the light tool. */
sealed interface LightCommand {
  /** Speak the brightness level (a camera estimate). */
  data object HowBright : LightCommand
  /** Which way the light is ("brighter to your left"). */
  data object WhereBright : LightCommand
  /** Is something in view blinking? */
  data object IsBlinking : LightCommand
  /** Measure again: the colour in colour mode, the level in light mode. */
  data object Again : LightCommand
  /** Switch to colour mode and name the colour now. */
  data object Colour : LightCommand
  /** Switch to the light probe. */
  data object Light : LightCommand
  data object ToneOff : LightCommand
  data object ToneOn : LightCommand
}

object LightGrammar {

  private val COLOUR =
      Regex(
          "^(?:what colou?r is (?:this|it|that|the .+)|what(?:'s| is) the colou?r(?: of (?:this|that|it|the .+))?|" +
              "which colou?r is (?:this|it|that)|what colou?r|(?:open |start |switch to )?(?:the )?colou?r (?:mode|detector|reader))$",
      )

  private val LIGHT =
      Regex(
          "^(?:(?:open |start |switch to )?(?:the )?light (?:detector|probe|meter|sensor|mode)|" +
              "is (?:the |a )?lights? on|are (?:the )?lights on|is it (?:light|dark)(?: in here)?|" +
              "where(?:'s| is) the light|is there (?:a )?light(?: on)?)$",
      )

  fun opens(normalized: String, @Suppress("UNUSED_PARAMETER") light: String): ToolRequest? =
      when {
        COLOUR.matches(normalized) -> ToolRequest(ToolId.LIGHT, mode = ToolRequest.MODE_COLOUR)
        LIGHT.matches(normalized) -> ToolRequest(ToolId.LIGHT)
        else -> null
      }

  private val HOW_BRIGHT =
      Regex(
          "^(?:how (?:bright|light|dark|sunny) is it(?: in here| here| now)?|how bright|how light|how dark|" +
              "(?:what(?:'s| is) the )?(?:light|brightness) level|brightness|is (?:the |a |that )?lights? on|" +
              "are (?:the )?lights on|is it (?:light|dark|bright)(?: in here)?|is it on|" +
              "are the curtains (?:open|closed|shut)|is the (?:screen|lamp|torch) on)$",
      )
  private val WHERE =
      Regex("^(?:where(?:'s| is) the (?:light|window|lamp|brightest(?: bit| part)?)|which way is (?:the )?(?:light|window)|where(?:'s| is) it brightest)$")
  private val BLINK =
      Regex("^(?:is (?:it|that|the light|something|anything) (?:blinking|flashing|flickering)|(?:any(?:thing)? )?blinking|flashing|is it on or off)$")
  private val AGAIN =
      Regex("^(?:again|(?:check|measure|look|try|do it|test) again|once more|what about (?:now|this|this one|that)|and (?:now|this|this one)|check (?:it|this)|next one)$")
  private val COLOUR_CMD =
      Regex("^(?:colou?rs?|(?:check|name|tell me) the colou?r|colou?r please|colou?r check)$")
  private val LIGHT_CMD =
      Regex("^(?:(?:back to |go to )?(?:the )?(?:light|tone|probe)(?: mode)?|light probe|light detector)$")
  private val TONE_OFF =
      Regex("^(?:(?:turn )?(?:the )?tone off|(?:turn )?off the tone|stop the tone|mute|silence|no tone|quiet the tone)$")
  private val TONE_ON =
      Regex("^(?:(?:turn )?(?:the )?tone (?:on|back on)|(?:turn )?on the tone|unmute|start the tone|tone please)$")

  /** A command inside the tool, or null. [normalized] is Phrases.normalize(transcript). */
  fun parse(normalized: String): LightCommand? =
      when {
        normalized.isEmpty() -> null
        TONE_OFF.matches(normalized) -> LightCommand.ToneOff
        TONE_ON.matches(normalized) -> LightCommand.ToneOn
        AGAIN.matches(normalized) -> LightCommand.Again
        COLOUR.matches(normalized) || COLOUR_CMD.matches(normalized) -> LightCommand.Colour
        WHERE.matches(normalized) -> LightCommand.WhereBright
        BLINK.matches(normalized) -> LightCommand.IsBlinking
        HOW_BRIGHT.matches(normalized) -> LightCommand.HowBright
        LIGHT_CMD.matches(normalized) || LIGHT.matches(normalized) -> LightCommand.Light
        else -> null
      }
}
