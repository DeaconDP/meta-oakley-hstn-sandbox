// GlassesCard - the compact card a glasses display shows in hands-free mode, and when to send it
//
// notes/hands-free-mode.md > Display is optional. Speech is the source of truth; the card mirrors
// it: the tool or screen name, one line of state, the last thing heard (shortened), and up to three
// hint phrases. Tools publish card state through ToolHub (HandsFreeSurface); they never call the
// display API.
//
// Each Display.sendContent replaces the whole screen and crosses the Bluetooth link, so CardThrottle
// sends only when the card changed, and at most once per [CardThrottle.minGapMs] (about 2 a second).
// A change inside the gap is held and the newest one is sent when the gap ends.
// Pure Kotlin, JVM-tested (HandsFreeTest).

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core

data class GlassesCard(
    /** "Main menu", "Mail reader". */
    val screen: String = "",
    /** One line: "Listening", "Reading page 3", "Glasses disconnected". */
    val state: String = "",
    /** The last thing heard, shortened. Empty if nothing yet. */
    val heard: String = "",
    /** Up to [MAX_HINTS] phrases: "read", "next", "main menu". */
    val hints: List<String> = emptyList(),
) {
  companion object {
    const val MAX_HINTS = 3
    const val MAX_STATE = 60
    const val MAX_HEARD = 40

    /** The card with every field trimmed to what fits a glance. */
    fun of(screen: String, state: String, heard: String, hints: List<String>): GlassesCard =
        GlassesCard(
            screen = shorten(screen, MAX_STATE),
            state = shorten(firstSentence(state), MAX_STATE),
            heard = shorten(heard, MAX_HEARD),
            hints = hints.map { it.trim() }.filter { it.isNotEmpty() }.distinct().take(MAX_HINTS),
        )

    /** At most [max] characters, cut at a word with an ellipsis. */
    fun shorten(text: String, max: Int): String {
      val t = text.trim().replace(Regex("\\s+"), " ")
      if (t.length <= max) return t
      val cut = t.substring(0, max - 1)
      val space = cut.lastIndexOf(' ')
      return (if (space > max / 2) cut.substring(0, space) else cut).trimEnd(',', ';', ':', '.', ' ') + "…"
    }

    /** "Main menu. Say read my book, ..." -> "Main menu." The rest was spoken, the card is a glance. */
    fun firstSentence(text: String): String {
      val t = text.trim()
      val end = Regex("[.!?](\\s|$)").find(t) ?: return t
      return t.substring(0, end.range.first + 1)
    }

    /** "Say: read · next · main menu" (empty if no hints). */
    fun hintLine(hints: List<String>, prefix: String = "Say: "): String =
        if (hints.isEmpty()) "" else prefix + hints.joinToString(" · ")
  }
}

/** What to do with a card offered at a moment. */
sealed interface CardDecision {
  /** Send it now. */
  data object Send : CardDecision

  /** Same as what's on the glasses (or already queued): nothing to do. */
  data object Unchanged : CardDecision

  /** Changed, but too soon: send the newest card after [delayMs]. */
  data class Later(val delayMs: Long) : CardDecision
}

/** Send-on-change with a minimum gap between sends. Not thread-safe: one caller (the main thread). */
class CardThrottle(val minGapMs: Long = MIN_GAP_MS) {
  companion object {
    /** About two updates a second. */
    const val MIN_GAP_MS = 500L
  }

  private var lastSent: GlassesCard? = null
  private var lastSentAtMs: Long = Long.MIN_VALUE / 2

  /** The card waiting for the gap to end, if any. */
  var pending: GlassesCard? = null
    private set

  fun offer(card: GlassesCard, nowMs: Long): CardDecision {
    if (card == lastSent) {
      pending = null
      return CardDecision.Unchanged
    }
    val wait = lastSentAtMs + minGapMs - nowMs
    if (wait > 0) {
      val alreadyWaiting = pending != null
      pending = card
      return if (alreadyWaiting) CardDecision.Unchanged else CardDecision.Later(wait)
    }
    pending = null
    return CardDecision.Send
  }

  /** The card actually went out at [nowMs]. */
  fun sent(card: GlassesCard, nowMs: Long) {
    lastSent = card
    lastSentAtMs = nowMs
    if (pending == card) pending = null
  }

  /** The gap ended: the held card to send now, if it still differs from what's shown. */
  fun takePending(nowMs: Long): GlassesCard? {
    val p = pending ?: return null
    return if (offer(p, nowMs) == CardDecision.Send) p else null
  }

  /** The display went away (or was cleared): the next card is sent whatever it is. */
  fun reset() {
    lastSent = null
    pending = null
    lastSentAtMs = Long.MIN_VALUE / 2
  }
}
