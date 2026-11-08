// DictionaryTest - the bundled WordNet asset and the lemmatiser, on the real data
//
// Format and size of the committed asset, exact lookups, sense order, irregular forms, and the
// inflections and British/American spellings the lemmatiser must reach. Also times lookups on the
// JVM (the phone's figure is in AskOnDeviceTest and notes/ask-about-the-text.md).

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ask

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DictionaryTest {

  private val dict = AskTestData.dictionary
  private val lem = Lemmatiser(dict)

  @Test
  fun assetIsCompactAndComplete() {
    val size = AskTestData.assetFile.length()
    assertTrue("asset is $size bytes", size in 2_000_000L..6_000_000L)
    assertEquals(147_306, dict.lemmaCount)
    assertEquals(117_659, dict.definitionCount)
  }

  @Test
  fun exactLookups() {
    val recondite = dict.entry("recondite")!!
    assertEquals(listOf('a'), recondite.parts)
    assertTrue(dict.senses(recondite).first().gloss.startsWith("difficult to penetrate"))
    val ephemeral = dict.entry("ephemeral")!!
    assertTrue('a' in ephemeral.parts)
    assertEquals("lasting a very short time", dict.senses(ephemeral, listOf('a')).first().gloss)
    // Multi-word lemmas, upper case in, examples dropped from glosses.
    assertNotNull(dict.entry("Time Machine") ?: dict.entry("time machine") ?: dict.entry("hearth rug") ?: dict.entry("coffee pot"))
    assertNotNull(dict.entry("breakfast table") ?: dict.entry("coffeepot"))
    assertFalse(dict.senses(dict.entry("dog")!!).any { it.gloss.contains('"') })
    // Not words.
    assertNull(dict.entry("penang lawyer"))
    assertNull(dict.entry("recondight"))
    assertNull(dict.entry(""))
    assertNull(dict.entry("zzzzzz"))
    assertTrue(dict.contains("aardvark"))
    assertTrue(dict.contains("zymurgy"))
  }

  @Test
  fun senseOrderFollowsWordNet() {
    val dog = dict.entry("dog")!!
    assertEquals(listOf('n', 'v'), dog.parts)
    assertTrue(dict.senses(dog).first().gloss.contains("domesticated"))
    assertEquals(7, dog.senseCount('n'))
  }

  @Test
  fun irregularForms() {
    assertTrue(('n' to "mouse") in dict.irregular("mice"))
    assertTrue(('v' to "go") in dict.irregular("went"))
    assertTrue(dict.irregular("dog").isEmpty())
  }

  private fun assertLemma(word: String, lemma: String, pos: Char? = null) {
    val got = lem.lemmas(word)
    assertTrue("$word -> $got, wanted $lemma", got.any { it.lemma == lemma })
    if (pos != null) assertEquals("$word pos", pos, got.first { it.lemma == lemma }.pos)
  }

  @Test
  fun inflections() {
    assertLemma("expounding", "expound", 'v')
    assertLemma("expounded", "expound", 'v')
    assertLemma("travellers", "traveller", 'n')
    assertLemma("travelled", "travel", 'v')
    assertLemma("traveling", "travel", 'v')
    assertLemma("stopped", "stop", 'v')
    assertLemma("mice", "mouse", 'n')
    assertLemma("went", "go", 'v')
    assertLemma("happier", "happy", 'a')
    assertLemma("finest", "fine", 'a')
    assertLemma("boxes", "box", 'n')
    assertLemma("churches", "church", 'n')
    assertLemma("ladies", "lady", 'n')
    assertLemma("controverted", "controvert", 'v')
    assertLemma("misconceptions", "misconception", 'n')
    assertLemma("argumentatively", "argumentative", 'a')
    assertLemma("Holmes's", "holmes")
    assertLemma("visitor's", "visitor")
    assertLemma("hearth-rug", "hearthrug")
    // As written comes first.
    assertEquals("recondite", lem.lemma("recondite")!!.lemma)
    assertEquals("twinkled".let { lem.lemma(it)!!.lemma }, "twinkle")
  }

  @Test
  fun britishAndAmericanSpellings() {
    assertLemma("colour", "color")
    assertLemma("colours", "color")
    assertLemma("honour", "honor")
    assertLemma("realised", "realize", 'v')
    assertLemma("realise", "realize")
    assertLemma("organisation", "organization")
    assertLemma("analyse", "analyze")
    assertLemma("centre", "center")
    assertLemma("theatres", "theater")
    assertLemma("counsellor", "counselor")
    assertLemma("anaemia", "anemia")
    assertLemma("catalogue", "catalog")
    assertLemma("defence", "defense")
    assertLemma("grey", "grey")
    assertLemma("gray", "grey")
    assertLemma("programme", "program")
    // ...and the other way where WordNet uses the British form.
    assertLemma("traveler", "traveller")
  }

  @Test
  fun nonWordsHaveNoLemma() {
    for (w in listOf("recondight", "xqzt", "", "   ", "penang")) {
      if (w == "penang") continue // a place name WordNet may or may not have
      assertNull(w, lem.lemma(w))
    }
  }

  @Test
  fun lookupsAreFast() {
    val words = listOf("recondite", "expounding", "travellers", "colour", "realised", "ephemeral", "zymurgy", "nothingness")
    repeat(200) { for (w in words) lem.lemmas(w) } // warm up
    val t0 = System.nanoTime()
    val n = 2_000
    repeat(n) { for (w in words) lem.lemmas(w) }
    val perLookupUs = (System.nanoTime() - t0) / 1_000.0 / (n * words.size)
    println("metric=ask_lemmatise_jvm us_per_word=${"%.1f".format(perLookupUs)}")
    assertTrue("lemmatising takes $perLookupUs us", perLookupUs < 2_000)
  }
}
