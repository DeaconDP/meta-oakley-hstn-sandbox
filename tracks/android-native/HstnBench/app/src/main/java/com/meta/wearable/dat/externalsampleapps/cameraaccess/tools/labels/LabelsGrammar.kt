// LabelsGrammar - what the user says to and inside the label reader
//
// [opens]: the phrases that open this tool from any tool ("scan this", "what's this product", "read
// the label"). GlobalGrammar calls it; add synonyms here, not there. [parse]: commands inside the
// tool (none yet: this tool is a stub; the feature agent adds "look it up", "cooking instructions",
// ...). ToolHub tries [parse] before the global grammar, so don't claim phrases that open other
// tools. Pure Kotlin (no Android imports), JVM-tested.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.labels

import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolRequest

/** Commands inside the label reader. Add them here. */
sealed interface LabelsCommand

object LabelsGrammar {

  private const val THING = "(?:product|item|thing|packet|pack|tin|can|jar|box|bottle|carton|tub)"

  private val OPEN =
      Regex(
          "^(?:scan(?: (?:this|it|that|the barcode|a barcode|the code|this code|the label|this label|$THING))?|" +
              "what(?:'s| is) (?:this|that) $THING|what $THING is (?:this|that)|" +
              "read (?:the|this) (?:label|packet|box|ingredients|tin)|" +
              "(?:open |start |switch to )?(?:the )?(?:label|barcode) (?:reader|scanner)|labels?)$",
      )

  fun opens(normalized: String, @Suppress("UNUSED_PARAMETER") light: String): ToolRequest? =
      if (OPEN.matches(normalized)) ToolRequest(ToolId.LABELS) else null

  /** A command inside the tool, or null. [normalized] is Phrases.normalize(transcript). */
  @Suppress("UNUSED_PARAMETER")
  fun parse(normalized: String): LabelsCommand? = null
}
