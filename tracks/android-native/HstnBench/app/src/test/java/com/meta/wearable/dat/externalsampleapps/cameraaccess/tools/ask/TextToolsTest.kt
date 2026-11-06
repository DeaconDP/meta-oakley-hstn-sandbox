// TextToolsTest - sentences, what's been read so far, mentions, search, recap, loose matching
//
// On the Conan Doyle and Wells fixture pages: "Mr." doesn't end a sentence, the unread rest of a
// page isn't searched, "Holmes" is found under "Hoimes"-style variants, a misheard "Bennett" still
// matches "Bennet", "the fire" isn't on these pages, and so on.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ask

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TextToolsTest {

  private val hound = Sentences.split(AskTestData.houndPage)
  private val time = Sentences.split(AskTestData.timePage)

  @Test
  fun splitsSentences() {
    assertTrue(hound[0].startsWith("Mr. Sherlock Holmes, who was usually very late"))
    assertTrue(hound[0].endsWith("breakfast table."))
    assertEquals("I stood upon the hearth-rug and picked up the stick which our visitor had left behind him the night before.", hound[1])
    assertEquals("\"Well, Watson, what do you make of it?\"", hound[3])
    assertEquals(5, hound.size)
    // A question with "said Filby" after it is one sentence; quotes stay with their sentence.
    assertTrue(time.any { it.startsWith("\"Is not that rather a large thing") && it.endsWith("red hair.") })
    assertEquals(listOf("Dr. Watson came.", "He sat down."), Sentences.split("Dr. Watson came. He sat down."))
    assertEquals(listOf("One.", "Two!", "Three?"), Sentences.split("One. Two! Three?"))
    assertEquals(listOf("No end"), Sentences.split("No end"))
    assertTrue(Sentences.split("  \n\n ").isEmpty())
  }

  @Test
  fun readSoFarStopsAtTheSentenceBeingRead() {
    val current = "His grey eyes shone and twinkled, and his usually pale face was flushed and animated."
    val read = ReadText.sentences(AskTestData.snapshot(AskTestData.houndPage, AskTestData.timePage, current = current))
    assertEquals(hound.size + 2, read.size)
    assertEquals(current, read.last())
    assertFalse("unread text searched", read.any { it.contains("Filby") })
    // The reader's chunk can be part of a sentence.
    val partial = ReadText.sentences(AskTestData.snapshot(AskTestData.timePage, current = "was expounding a recondite matter to us"))
    assertEquals(1, partial.size)
    // No current sentence (page finished): all of it. Unknown current: all of it.
    assertEquals(time.size, ReadText.sentences(AskTestData.snapshot(AskTestData.timePage)).size)
    assertEquals(time.size, ReadText.sentences(AskTestData.snapshot(AskTestData.timePage, current = "Something else entirely here.")).size)
    assertTrue(ReadText.sentences(null).isEmpty())
  }

  @Test
  fun tailKeepsWholeSentencesUpToTheLimit() {
    val snap = AskTestData.snapshot(AskTestData.houndPage, AskTestData.timePage, current = "It is extraordinarily simple, and you will soon admit as much on reasonable grounds.\"")
    val tail = ReadText.tail(snap, maxChars = 200)!!
    assertTrue(tail.length <= 200)
    assertTrue(tail, tail.endsWith("reasonable grounds.\""))
    assertFalse(tail.contains("Filby"))
    assertTrue(ReadText.tail(snap)!!.startsWith("Mr. Sherlock Holmes"))
    assertNull(ReadText.tail(null))
  }

  @Test
  fun soundAlikeAndLooseNames() {
    assertEquals(Words.soundKey("recondite"), Words.soundKey("recondight"))
    assertEquals(Words.soundKey("Bennet"), Words.soundKey("Bennett"))
    assertTrue(Words.sameName("bennett", "bennet"))
    assertTrue(Words.sameName("holmes", "holmes"))
    assertTrue(Words.sameName("holms", "holmes"))
    assertTrue(Words.sameName("watsons", "watson"))
    assertFalse(Words.sameName("watson", "wilson"))
    assertTrue(Words.letterSimilarity("recon dight", "recondite") >= 0.6)
    assertTrue(Words.soundSimilarity("recon dight", "recondite") >= 0.99)
    assertEquals(3, Words.levenshtein("kitten", "sitting"))
  }

  @Test
  fun mentionsOfAName() {
    val text = hound + Sentences.split(AskTestData.houndNextPage)
    val holmes = Mentions.find(text, "holmes")
    assertEquals(listOf(0, 4), holmes.map { it.index })
    assertEquals("Mr. Sherlock Holmes", Mentions.displayName(text, holmes, "holmes"))
    assertEquals("Watson", Mentions.displayName(text, Mentions.find(text, "watson"), "watson"))
    assertEquals("Time Traveller", Mentions.displayName(time, Mentions.find(time, "the time traveller"), "the time traveller"))
    val watson = Mentions.find(text, "watson")
    assertEquals(2, watson.size)
    assertTrue(watson[1].sentence.contains("visitor's stick"))
    // Title dropped, surname heard a little wrong.
    assertEquals(holmes, Mentions.find(text, "mr holms"))
    assertEquals(holmes, Mentions.find(text, "Sherlock Holmes"))
    assertEquals(holmes, Mentions.find(text, "Mister Sherlock Holmes"))
    // Not in the text.
    assertTrue(Mentions.find(text, "mr bennet").isEmpty())
    assertTrue(Mentions.find(time, "the time machine").isEmpty())
    // "The Time Traveller": both words needed.
    assertEquals(1, Mentions.find(time, "the time traveller").size)
    assertEquals("Filby", Mentions.displayName(time, Mentions.find(time, "filbee"), "filbee"))
  }

  @Test
  fun searchFindsTheSentencesAskedAbout() {
    val text = hound + Sentences.split(AskTestData.houndNextPage)
    val stick = Search.find(text, "the stick")
    assertEquals(2, stick.size)
    assertTrue(stick[0].sentence.contains("picked up the stick"))
    assertTrue(Search.find(text, "the fire").isEmpty())
    assertEquals(1, Search.find(text, "coffee pot").size)
    assertEquals(1, Search.find(text, "eyes in the back of his head").size)
    assertTrue(Search.find(time, "geometry")[0].sentence.contains("taught you at school"))
    // Inflections: "twinkling" finds "twinkled".
    assertEquals(1, Search.find(time, "twinkling eyes").size)
  }

  @Test
  fun recapIsTheLastFewSentences() {
    val r = Recap.last(hound)
    assertEquals(hound.last(), r.last())
    assertTrue(r.sumOf { Words.of(it).size } <= 60)
    assertEquals(1, Recap.last(listOf("A very long sentence " + "word ".repeat(100))).size)
    assertTrue(Recap.last(emptyList()).isEmpty())
  }
}
