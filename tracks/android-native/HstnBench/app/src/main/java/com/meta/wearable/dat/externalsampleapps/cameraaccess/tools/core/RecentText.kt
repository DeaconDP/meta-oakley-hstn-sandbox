// RecentText - the text each tool has read out recently, for "ask about the text"
//
// A question like "what does ephemeral mean?" or "who's Mr. Bennet?" is about what the user just
// heard. Tools publish that text here as they read it: the book reader adds each page as it starts
// reading it (all pages read this session) and keeps the current sentence up to date; the mail
// reader publishes the letter. AskAboutText gets a [Snapshot] of the open tool (or, if it has
// nothing, the tool that published most recently). Only text is kept, never images, and only in
// memory for this app session. Bounded: the oldest passages go first past [maxChars] per tool.
// Pure Kotlin, thread-safe, JVM-tested.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core

class RecentText(private val maxChars: Int = 40_000, private val clock: () -> Long = System::currentTimeMillis) {

  /**
   * What [tool] has read. [passages] oldest first (book pages, a letter); [current] is the sentence
   * being read now, if the tool tracks one; [title] is optional context ("Letter from ...").
   */
  data class Snapshot(
      val tool: ToolId,
      val passages: List<String>,
      val current: String?,
      val title: String?,
      val updatedMs: Long,
  ) {
    /** All passages joined, oldest first. */
    val fullText: String
      get() = passages.joinToString("\n\n")
  }

  private class Entry(val passages: ArrayDeque<Pair<String, String>> = ArrayDeque()) {
    var current: String? = null
    var title: String? = null
    var updatedMs = 0L
  }

  private val entries = mutableMapOf<ToolId, Entry>()

  /**
   * Adds a passage (a page, a letter). [key] identifies it: publishing the same key again replaces
   * that passage (a page re-read after a correction) instead of adding a copy. Defaults to the text.
   */
  @Synchronized
  fun addPassage(tool: ToolId, text: String, key: String = text) {
    if (text.isBlank()) return
    val e = entries.getOrPut(tool) { Entry() }
    val at = e.passages.indexOfFirst { it.first == key }
    if (at >= 0) e.passages[at] = key to text else e.passages.addLast(key to text)
    while (e.passages.size > 1 && e.passages.sumOf { it.second.length } > maxChars) e.passages.removeFirst()
    e.updatedMs = clock()
  }

  /** The sentence being read now (null when nothing is being read). */
  @Synchronized
  fun setCurrent(tool: ToolId, sentence: String?) {
    val e = entries.getOrPut(tool) { Entry() }
    e.current = sentence
    e.updatedMs = clock()
  }

  @Synchronized
  fun setTitle(tool: ToolId, title: String?) {
    entries.getOrPut(tool) { Entry() }.title = title
  }

  /** Forget what [tool] read (a new letter replaces the old one, say). */
  @Synchronized
  fun clear(tool: ToolId) {
    entries.remove(tool)
  }

  @Synchronized
  fun snapshot(tool: ToolId): Snapshot? {
    val e = entries[tool] ?: return null
    if (e.passages.isEmpty() && e.current == null) return null
    return Snapshot(tool, e.passages.map { it.second }, e.current, e.title, e.updatedMs)
  }

  /** The tool that published most recently, or null if nothing has been read. */
  @Synchronized
  fun latest(): Snapshot? =
      entries.keys.mapNotNull { snapshot(it) }.maxByOrNull { it.updatedMs }

  /** [tool]'s text if it has any, else the most recent text from any tool. */
  fun forQuestion(tool: ToolId?): Snapshot? = tool?.let { snapshot(it) } ?: latest()
}
