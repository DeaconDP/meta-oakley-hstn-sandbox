// EchoGuard - the mic hears our own voice; this tells it apart from the user
//
// Hands-free listening runs while a tool is talking (reading a book page, a letter, a label). The
// glasses' or the phone's mic picks that speech up and the recogniser turns it into text, so a word
// like "Stop!" read out from a book would otherwise pause the reader. ToolHub feeds every utterance
// start and end in here, and drops transcripts that are just something we are saying, or said a
// moment ago. Pure Kotlin, JVM-tested (book/VoiceCommandsTest). Moved out of book/VoiceCommands.kt
// when the second tool needed it.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core

/**
 * Remembers what the reader is saying, or said a moment ago, so the mic hearing the book (or our own
 * replies) isn't taken as the user talking.
 *
 * A transcript is an echo when its words appear as a run inside something that is being spoken
 * right now. That catches a command word read out from the book ("Stop!" cried Holmes), including
 * as a partial result. In the [tailMs] after speech ends (recogniser latency), only fragments of
 * [MIN_TAIL_WORDS]+ words count: echoes arrive as phrases, while a user answering a prompt ("Say
 * read to start" → "read") says one or two words and must be heard. After that nothing is filtered.
 */
class EchoGuard(private val tailMs: Long = 2_000L, private val maxEntries: Int = 4) {

  private companion object {
    const val MIN_TAIL_WORDS = 3
  }

  private class Spoken(val words: List<String>, var endMs: Long = Long.MAX_VALUE)

  private val recent = ArrayDeque<Spoken>()

  /** Call when speech of [text] starts. */
  @Synchronized
  fun spoke(text: String, nowMs: Long) {
    val words = words(text)
    if (words.isEmpty()) return
    // Speech is sequential: whatever was playing before has ended.
    recent.lastOrNull()?.let { if (it.endMs == Long.MAX_VALUE) it.endMs = nowMs }
    recent.addLast(Spoken(words))
    while (recent.size > maxEntries) recent.removeFirst()
  }

  /** Call when speech finishes or is cut off. */
  @Synchronized
  fun finished(nowMs: Long) {
    recent.lastOrNull()?.let { if (it.endMs == Long.MAX_VALUE) it.endMs = nowMs }
  }

  @Synchronized
  fun clear() = recent.clear()

  @Synchronized
  fun isEcho(transcript: String, nowMs: Long): Boolean {
    val heard = words(transcript)
    if (heard.isEmpty()) return false
    return recent.any { s ->
      val speaking = s.endMs == Long.MAX_VALUE
      val inTail = !speaking && nowMs - s.endMs <= tailMs && heard.size >= MIN_TAIL_WORDS
      (speaking || inTail) && containsRun(s.words, heard)
    }
  }

  /** [heard] appears as a contiguous run in [spoken], allowing one misheard word in four. */
  private fun containsRun(spoken: List<String>, heard: List<String>): Boolean {
    val allowedMisses = heard.size / 4
    for (start in spoken.indices) {
      if (spoken[start] != heard[0] && allowedMisses == 0) continue
      var misses = 0
      for ((k, w) in heard.withIndex()) {
        if (spoken.getOrNull(start + k) != w) misses++
        if (misses > allowedMisses) break
      }
      if (misses <= allowedMisses) return true
    }
    return false
  }

  private fun words(text: String): List<String> =
      text.lowercase().replace('’', '\'').split(Regex("[^a-z0-9']+")).filter { it.isNotEmpty() }
}
