package com.meta.wearable.dat.externalsampleapps.cameraaccess.book

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SpeechChunkerTest {

  @Test
  fun splitsSentencesButNotAbbreviationsOrInitials() {
    assertEquals(
        listOf(
            "Mr. Sherlock Holmes was seated at the breakfast table.",
            "Dr. Mortimer had left his stick.",
            "J. R. R. Tolkien wrote it!",
            "Did he?",
        ),
        SpeechChunker.sentences(
            "Mr. Sherlock Holmes was seated at the breakfast table. Dr. Mortimer had left his " +
                "stick. J. R. R. Tolkien wrote it! Did he?"
        ),
    )
  }

  @Test
  fun quotedQuestionFollowedBySaidStaysOneSentence() {
    val s = "\"Is not that rather a large thing to expect?\" said Filby. He had red hair."
    assertEquals(
        listOf("\"Is not that rather a large thing to expect?\" said Filby.", "He had red hair."),
        SpeechChunker.sentences(s),
    )
  }

  @Test
  fun closingQuoteStaysWithItsSentence() {
    assertEquals(
        listOf("\"Well, Watson, what do you make of it?\"", "Holmes was sitting with his back to me."),
        SpeechChunker.sentences(
            "\"Well, Watson, what do you make of it?\" Holmes was sitting with his back to me."
        ),
    )
  }

  @Test
  fun longSentencesSplitAtClausesWithinMax() {
    val chunks = SpeechChunker.chunk(BookFixtures.houndParagraphs, maxChars = 80)
    assertTrue(chunks.all { it.text.length <= 80 })
    // Chunks of one sentence reassemble to the sentence.
    for ((_, group) in chunks.groupBy { it.sentence }) {
      assertEquals(group[0].sentenceText, group.joinToString(" ") { it.text })
    }
    assertEquals(3, chunks.map { it.paragraph }.distinct().size)
  }

  @Test
  fun unpunctuatedRunOnIsHardWrapped() {
    val words = (1..60).joinToString(" ") { "word$it" }
    val pieces = SpeechChunker.clauses(words, maxChars = 100)
    assertTrue(pieces.size > 1)
    assertTrue(pieces.all { it.length <= 100 })
    assertEquals(words, pieces.joinToString(" "))
  }

  @Test
  fun backASentence() {
    val chunks =
        SpeechChunker.chunk(listOf("One. Two has a long tail, with a clause, and another clause here. Three."), maxChars = 30)
    val three = chunks.indexOfFirst { it.text == "Three." }
    val twoStart = chunks.indexOfFirst { it.sentence == 1 }
    assertEquals(twoStart, SpeechChunker.previousSentenceStart(chunks, three))
    // From the middle of sentence two, back goes to sentence one.
    assertEquals(0, SpeechChunker.previousSentenceStart(chunks, twoStart + 1))
    assertEquals(0, SpeechChunker.previousSentenceStart(chunks, 0))
  }
}

class BookmarkTest {

  private val chunks = SpeechChunker.chunk(BookFixtures.houndParagraphs, maxChars = 80)

  @Test
  fun encodeDecodeRoundTrip() {
    val b = Bookmark(12, "It was a fine,\tthick piece of wood.")
    val decoded = Bookmark.decode(b.encode())!!
    assertEquals(12, decoded.pagesRead)
    assertEquals("It was a fine, thick piece of wood.", decoded.lastSentence)
    assertNull(Bookmark.decode(""))
    assertNull(Bookmark.decode("garbage"))
  }

  @Test
  fun resumesAfterTheLastSentenceEvenWithOcrNoise() {
    val target = chunks.first { it.text.startsWith("\"Well, Watson") }
    val bookmark = Bookmark(3, target.sentenceText.replace("Watson", "Watsou"))
    val idx = bookmark.resumeIndex(chunks)!!
    assertTrue(chunks[idx].text.startsWith("Holmes was sitting"))
  }

  @Test
  fun lastSentenceOfPageResumesAtEnd() {
    val last = chunks.last()
    assertEquals(chunks.size, Bookmark(3, last.sentenceText).resumeIndex(chunks))
  }

  @Test
  fun sentenceNotOnThisPageGivesNull() {
    assertNull(Bookmark(3, "Call me Ishmael. Some years ago, never mind how long.").resumeIndex(chunks))
  }
}
