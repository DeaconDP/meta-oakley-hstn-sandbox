// LightGrammar - what the user says to and inside the light and colour tool
//
// [opens]: the phrases that open this tool from any tool. "What colour is this" opens it in colour
// mode (ToolRequest.MODE_COLOUR); "light detector", "is the light on" open the light probe.
// GlobalGrammar calls it; add synonyms here, not there. [parse]: commands inside the tool (none yet:
// this tool is a stub; the feature agent adds them). ToolHub tries [parse] before the global
// grammar, so don't claim phrases that open other tools. Pure Kotlin (no Android imports), JVM-tested.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.light

import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolRequest

/** Commands inside the light tool. Add them here. */
sealed interface LightCommand

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

  /** A command inside the tool, or null. [normalized] is Phrases.normalize(transcript). */
  @Suppress("UNUSED_PARAMETER")
  fun parse(normalized: String): LightCommand? = null
}
