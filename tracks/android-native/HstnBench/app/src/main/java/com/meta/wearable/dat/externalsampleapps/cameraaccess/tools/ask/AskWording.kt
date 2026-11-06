// AskWording - the sentences "Ask about the text" speaks
//
// Answers are heard, not read, through the glasses' speakers while the user holds a book: short,
// the useful part first, no lists, and always a way on ("say more", "say next"). Quotes from the
// text are clipped to about 30 words around what was asked. Kept in Kotlin rather than strings.xml
// because they're built from parts and pinned by JVM tests (AskWordingTest, OnDeviceAskTest); the
// Android-only lines are in res/values/strings_ask.xml. Pure Kotlin.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ask

object AskWording {

  const val CAN_ONLY =
      "I can only define words, tell you who someone is, recap, and find things in the text. " +
          "I can't answer that one."
  const val ASKING_ONLINE = "Asking online."
  const val NOTHING_MORE = "That's all I have."
  const val NO_WORD_YET = "Ask me what a word means first, then say spell it."
  const val NOTHING_TO_UNDO = "Say the word again, or say spell, then the word."
  const val NOT_READY = "The dictionary is still loading. Ask me again in a moment."
  const val CARRY_ON_HINT = "Say carry on to keep reading."
  const val NOTHING_READ = "I haven't read anything yet. Once I've read something, you can ask me about it."

  private val POS_NAMES = mapOf('n' to "noun", 'v' to "verb", 'a' to "adjective", 'r' to "adverb")

  fun posName(pos: Char): String = POS_NAMES[pos] ?: "word"

  private fun article(word: String) = if ((word.firstOrNull()?.lowercaseChar() ?: 'x') in "aeiou") "an" else "a"

  /** "Recondite, adjective: difficult to penetrate." plus a second sense if both are short. */
  fun definition(word: String, senses: List<Dictionary.Sense>, from: String? = null): Pair<String, List<String>> {
    if (senses.isEmpty()) return notInDictionary(word) to emptyList()
    val first = senses[0]
    val head = buildString {
      append(capitalise(word))
      if (from != null && from != word) append(", from ").append(from)
      append(", ").append(posName(first.pos)).append(": ").append(sentence(first.gloss))
    }
    var used = 1
    val text = StringBuilder(head)
    val second = senses.getOrNull(1)
    if (second != null && first.gloss.length + second.gloss.length < 150) {
      text.append(' ').append(if (second.pos == first.pos) "Or: " else "As ${article(posName(second.pos))} ${posName(second.pos)}: ")
          .append(sentence(second.gloss))
      used = 2
    }
    val rest = senses.drop(used).take(MAX_SENSES - used)
    val chunks = rest.chunked(2).map { pair ->
      var pos = senses[used - 1].pos
      pair.joinToString(" ") { s ->
        val lead = if (s.pos != pos) "As ${article(posName(s.pos))} ${posName(s.pos)}: " else "Another meaning: "
        pos = s.pos
        lead + sentence(s.gloss)
      }.also { used += pair.size }
    }
    if (chunks.isNotEmpty()) text.append(" Say more for other meanings.")
    return text.toString() to chunks
  }

  fun didYouMean(word: String) = "Did you mean ${word}?"

  fun notInDictionary(word: String) = "I couldn't find ${word} in my dictionary."

  fun spell(word: String): String {
    val letters = word.trim().mapNotNull { c ->
      when {
        c.isLetterOrDigit() -> c.uppercaseChar().toString()
        c == '-' -> "hyphen"
        c == '\'' || c == '’' -> "apostrophe"
        c == ' ' -> "space"
        else -> null
      }
    }
    return "${capitalise(word.trim())} is spelt ${letters.joinToString(", ")}."
  }

  fun notReadAbout(name: String) = "I haven't read anything about $name yet."

  /** "Holmes first comes up here: ... Most recently: ..." [more] is the rest, most recent first. */
  fun mentions(rawName: String, found: List<Found>, subjectKeys: List<String>, lastTime: Boolean): Pair<String, List<String>> {
    val name = capitalise(rawName)
    val prefix = if (lastTime) "Last time: " else ""
    if (found.size == 1) return "$prefix$name is mentioned once: ${clip(found[0].sentence, subjectKeys)}" to emptyList()
    val first = found.first()
    val latest = found.drop(1).takeLast(2)
    val words = (listOf(first) + latest).sumOf { Words.of(it.sentence).size }
    val spoken = if (words <= 70) latest else latest.takeLast(1)
    val text = buildString {
      append(prefix).append(name).append(" first comes up here: ").append(clip(first.sentence, subjectKeys))
      append(" Most recently: ").append(spoken.joinToString(" ") { clip(it.sentence, subjectKeys) })
    }
    val rest = found.drop(1).dropLast(spoken.size).asReversed().map { "Earlier: " + clip(it.sentence, subjectKeys) }
    return (if (rest.isNotEmpty()) "$text Say more for other mentions." else text) to rest
  }

  fun nothingFound(subject: String) = "I didn't find anything about $subject in what I've read."

  /** "About the fire: ... That's 1 of 3. Say next for the next one." */
  fun matches(subject: String, found: List<Found>, keys: List<String>): Pair<String, List<String>> {
    val head = "About $subject: ${clip(found[0].sentence, keys)}"
    val rest = found.drop(1).mapIndexed { i, f -> "Match ${i + 2} of ${found.size}: ${clip(f.sentence, keys)}" }
    return (if (rest.isEmpty()) head else "$head That's 1 of ${found.size}. Say next for the next one.") to rest
  }

  fun recap(sentences: List<String>, lastTime: Boolean): String =
      (if (lastTime) "Last time, we left off here: " else "The last bit was: ") + sentences.joinToString(" ")

  // MARK: - Helpers

  private const val MAX_SENSES = 8
  private const val CLIP_WORDS = 30

  fun capitalise(s: String) = s.replaceFirstChar { it.uppercaseChar() }

  /** A gloss as a spoken sentence: capital not needed (it follows a colon), one full stop. */
  fun sentence(gloss: String): String {
    val g = gloss.trim().trimEnd('.', ';', ',')
    return "$g."
  }

  /** [sentence] cut to about 30 words around the first of [keys], with "..." where cut. */
  fun clip(sentence: String, keys: List<String>): String {
    val words = sentence.split(' ').filter { it.isNotEmpty() }
    if (words.size <= CLIP_WORDS) return sentence
    val at = words.indexOfFirst { w -> keys.any { Words.sameName(it, Words.norm(w.trim('"', '“', '”', ',', '.', '?', '!', ';', ':'))) } }
        .coerceAtLeast(0)
    val start = (at - CLIP_WORDS / 3).coerceIn(0, words.size - CLIP_WORDS)
    val end = start + CLIP_WORDS
    return (if (start > 0) "... " else "") + words.subList(start, end).joinToString(" ") + (if (end < words.size) " ..." else "")
  }

  /** How to say a name the user asked about that isn't in the text: "mr bennet" -> "Mr. Bennet". */
  fun spokenName(subject: String): String =
      subject.trim().split(Regex("\\s+")).joinToString(" ") { w ->
        when (w.lowercase()) {
          "mr", "mrs", "ms", "dr", "st" -> capitalise(w.lowercase()) + "."
          "the", "of", "a", "an" -> w.lowercase()
          else -> capitalise(w)
        }
      }
}
