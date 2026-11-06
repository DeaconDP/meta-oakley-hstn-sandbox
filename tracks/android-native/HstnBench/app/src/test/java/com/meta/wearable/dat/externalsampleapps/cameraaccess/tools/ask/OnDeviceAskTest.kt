// OnDeviceAskTest - whole questions answered on the device, as ToolHub would ask them
//
// Real dictionary, book fixture text, the reader part-way down a page. Covers each kind of question
// and its follow-ups: define (+ "more", "spell it"), a misheard word ("Did you mean recondite?",
// then "no"), who, what, recap (this session and last session), find (+ "next"), open questions
// with no online path, and nothing read yet. Also WordLookup's choices directly.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ask

import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.AskResult
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.GlobalCommand
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class OnDeviceAskTest {

  private val dict = AskTestData.dictionary
  private val lookup = WordLookup(dict)

  /** Both pages read, the reader on the Time Machine page's second sentence. */
  private val reading = AskTestData.snapshot(
      AskTestData.houndPage, AskTestData.houndNextPage, AskTestData.timePage,
      current = "His grey eyes shone and twinkled, and his usually pale face was flushed and animated.",
  )

  @Before fun setUp() = AskGrammar.FollowUps.close()

  @After fun tearDown() = AskGrammar.FollowUps.close()

  private fun ask(a: OnDeviceAsk, q: String, snap: com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.RecentText.Snapshot? = reading, notes: MutableList<String>? = null): AskResult =
      runBlocking { a.answer(GlobalCommand.Ask(q), snap) { notes?.add(it) } }

  private fun say(a: OnDeviceAsk, q: String, snap: com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.RecentText.Snapshot? = reading): String {
    val r = ask(a, q, snap)
    assertTrue("$q -> $r", r is AskResult.Answer)
    return (r as AskResult.Answer).text.also { println("Q: $q\nA: $it") }
  }

  private fun asker(previous: String? = null, online: OnlineAsk? = null) =
      OnDeviceAsk(dictionary = { dict }, previousSession = { previous }, online = online)

  @Test
  fun definesAWordFromTheText() {
    val a = asker()
    val first = say(a, "What does recondite mean?")
    assertTrue(first, first.startsWith("Recondite, adjective: difficult to penetrate"))
    assertTrue("hint once", first.endsWith(AskWording.CARRY_ON_HINT))
    // WordNet has one sense of recondite.
    assertEquals(AskWording.NOTHING_MORE, say(a, "more"))
    assertEquals("Recondite is spelt R, E, C, O, N, D, I, T, E.", say(a, "spell it"))
    // "pale" has several: two at first, then "more" two at a time, then nothing more.
    val pale = say(a, "what does pale mean")
    assertTrue(pale, pale.startsWith("Pale, adjective: very light colored; highly diluted with white. Or: (of light) lacking in intensity"))
    assertTrue(pale, pale.endsWith("Say more for other meanings."))
    val more = say(a, "more")
    assertTrue(more, more.startsWith("Another meaning: lacking in vitality"))
    assertFalse(more.contains(AskWording.CARRY_ON_HINT))
    assertTrue(say(a, "more").contains("As a verb: turn pale, as if in fear."))
    assertTrue(say(a, "tell me more").startsWith("As a noun: a wooden strip forming part of a fence"))
    assertEquals(AskWording.NOTHING_MORE, say(a, "more"))
  }

  @Test
  fun inflectedWordInTheTextLeadsWithItsPartOfSpeech() {
    val a = asker()
    val text = say(a, "what does expounding mean")
    assertTrue(text, text.startsWith("Expounding, from expound, verb:"))
    // Asking for the base form finds the inflection in the text too.
    val base = say(a, "define expound")
    assertTrue(base, base.startsWith("Expound, verb:"))
  }

  @Test
  fun misheardWordOffersTheClosestWordInTheText() {
    val a = asker()
    val text = say(a, "what does recon dight mean")
    assertTrue(text, text.startsWith("Did you mean recondite? Recondite, adjective:"))
    assertEquals("Recondite is spelt R, E, C, O, N, D, I, T, E.", say(a, "spell it"))
    // Not a WordNet word, but sounds like one in the text.
    assertTrue(say(asker(), "what does reconnect mean").startsWith("Did you mean recondite?"))
    // A real word that sounds like one in the text: offered the text's word, "no" gets the one heard.
    val b = asker()
    val corrected = say(b, "what does tinkled mean")
    assertTrue(corrected, corrected.startsWith("Did you mean twinkled? Twinkled, from twinkle, verb:"))
    val asHeard = say(b, "no")
    assertTrue(asHeard, asHeard.startsWith("Tinkled, from tinkle, verb:"))
    // "No" is only offered straight after a "Did you mean".
    assertEquals(null, AskGrammar.classify("no"))
  }

  @Test
  fun wordNotInTheTextIsLookedUpAsHeard() {
    val a = asker()
    val text = say(a, "what does ephemeral mean")
    assertTrue(text, text.startsWith("Ephemeral, adjective:"))
    assertTrue(say(a, "define colour").startsWith("Colour, noun:"))
    assertTrue(say(a, "define realised").startsWith("Realised, from realise, verb:"))
    assertEquals(AskWording.notInDictionary("penang lawyer"), say(a, "what does Penang lawyer mean").removeSuffix(" " + AskWording.CARRY_ON_HINT))
    assertEquals(AskWording.notInDictionary("blorptastic"), say(a, "define blorptastic"))
  }

  @Test
  fun wordLookupChoices() {
    val read = ReadText.sentences(reading)
    assertEquals(WordLookup.Choice("recondite", "recondite", inText = true, corrected = false), lookup.choose("recondite", read))
    assertEquals(WordLookup.Choice("expound", "expound", inText = true, corrected = false), lookup.choose("expound", read))
    assertEquals("expounding", lookup.inText("expounds", read))
    assertEquals("recondite", lookup.choose("wreck on dight", read)!!.word)
    assertEquals("twinkled", lookup.inText("twinkle", read))
    // Words further down the page (not read yet) aren't offered.
    assertEquals("contra vert", lookup.choose("contra vert", read)!!.word)
    assertEquals("controvert", lookup.choose("contra vert", Sentences.split(AskTestData.timePage))!!.word)
    assertEquals("recon dight", lookup.choose("recon dight", read, allowCorrection = false)!!.word)
    // A dictionary word with nothing like it in the text stays as heard.
    assertEquals(WordLookup.Choice("gregarious", "gregarious", inText = false, corrected = false), lookup.choose("gregarious", read))
  }

  @Test
  fun whoIsSomeone() {
    val a = asker()
    val holmes = say(a, "who is Holmes")
    assertTrue(holmes, holmes.startsWith("Mr. Sherlock Holmes first comes up here: Mr. Sherlock Holmes, who was usually very late"))
    assertTrue(holmes, holmes.contains("Most recently: Holmes was sitting with his back to me"))
    val watson = say(a, "who's Watson?")
    assertTrue(watson, watson.startsWith("Watson first comes up here: \"Well, Watson"))
    assertEquals(AskWording.notReadAbout("Mr. Bennet"), say(a, "Who is Mr. Bennet?"))
    // Only what's been read: Filby is further down the page.
    assertEquals(AskWording.notReadAbout("Filby"), say(a, "who is Filby"))
    val all = AskTestData.snapshot(AskTestData.timePage)
    assertTrue(say(a, "who is Filby", all).startsWith("Filby is mentioned once: \"Is not that rather a large thing"))
  }

  @Test
  fun whatIsANameOrAWord() {
    val a = asker()
    assertTrue(say(a, "what's the time traveller").startsWith("Time Traveller is mentioned once:"))
    // Not in the text, but WordNet has it: the dictionary answers.
    assertTrue(say(a, "what's the Time Machine?").startsWith("Time machine, noun: a science fiction machine"))
    assertEquals(AskWording.notReadAbout("Morlocks"), say(a, "what are the Morlocks"))
    assertTrue(say(a, "what is the geometry", AskTestData.snapshot(AskTestData.timePage)).startsWith("Geometry is mentioned once"))
  }

  @Test
  fun recapThisSessionAndLastSession() {
    val a = asker(previous = "He sat by the fire. Then the letter came, and he read it twice.")
    val now = say(a, "recap")
    assertTrue(now, now.startsWith("The last bit was: "))
    assertTrue(now, now.contains("His grey eyes shone and twinkled"))
    assertFalse(now, now.contains("Filby"))
    // Nothing read yet this session: the end of the last one, kept with the bookmark.
    val last = say(a, "what happened last time", snap = null)
    assertEquals("Last time, we left off here: He sat by the fire. Then the letter came, and he read it twice.", last)
    // Who and find also fall back to last session's text when nothing's read yet.
    assertTrue(say(a, "what did it say about the fire", snap = null).startsWith("About the fire: He sat by the fire."))
    assertEquals(AskResult.NothingRead, ask(asker(), "what happened last time", snap = null))
  }

  @Test
  fun findAndNext() {
    val a = asker()
    val stick = say(a, "what did it say about the stick")
    assertTrue(stick, stick.startsWith("About the stick: I stood upon the hearth-rug and picked up the stick"))
    assertTrue(stick, stick.contains("That's 1 of 2. Say next for the next one."))
    val next = say(a, "next")
    assertTrue(next, next.startsWith("Match 2 of 2: \"But, tell me, Watson, what do you make of our visitor's stick?"))
    assertEquals(AskWording.NOTHING_MORE, say(a, "next"))
    assertEquals(AskWording.nothingFound("the fire"), say(a, "what did it say about the fire"))
  }

  @Test
  fun openQuestionsAreDeclinedHonestlyWithoutAKey() {
    val a = asker()
    assertEquals(AskWording.CAN_ONLY, say(a, "why did he do that").removeSuffix(" " + AskWording.CARRY_ON_HINT))
  }

  @Test
  fun openQuestionsGoOnlineOnlyWithAKeyAndSayAskingOnlineFirst() {
    var sent: Pair<String, String>? = null
    val a = asker(online = { q, t -> sent = q to t; AskResult.Answer("Because he wanted to test Watson.") })
    val notes = mutableListOf<String>()
    val r = ask(a, "why did he do that", notes = notes)
    assertEquals(listOf(AskWording.ASKING_ONLINE), notes)
    assertTrue(r is AskResult.Answer && r.text.startsWith("Because he wanted to test Watson."))
    assertEquals("why did he do that", sent!!.first)
    // Only the text read so far, never the unread rest of the page.
    assertTrue(sent!!.second.contains("recondite"))
    assertFalse(sent!!.second.contains("Filby"))
    // On-device kinds never go online.
    sent = null
    say(a, "what does recondite mean")
    say(a, "who is Holmes")
    assertEquals(null, sent)
  }

  @Test
  fun nothingReadYet() {
    val a = asker()
    assertEquals(AskResult.NothingRead, ask(a, "who is Holmes", snap = null))
    assertEquals(AskResult.NothingRead, ask(a, "what did it say about the fire", snap = null))
    // A definition doesn't need any text.
    assertTrue(say(a, "what does ephemeral mean", snap = null).startsWith("Ephemeral, adjective:"))
    assertEquals(AskWording.NO_WORD_YET, say(asker(), "spell it", snap = null))
  }

  @Test
  fun mailTextWorksTheSameWay() {
    val letter = "Dear Mr. Bennet, Your account is overdue. Please pay the balance by the fourteenth of March. Yours sincerely, Hannah Price, Accounts."
    val snap = AskTestData.snapshot(letter, tool = ToolId.MAIL)
    val a = asker()
    assertTrue(say(a, "who is Mr Bennett", snap).startsWith("Mr. Bennet is mentioned once: Dear Mr. Bennet"))
    assertTrue(say(a, "what did it say about the balance", snap).contains("fourteenth of March"))
    assertFalse("no carry-on hint outside the book", say(a, "what does overdue mean", snap).contains(AskWording.CARRY_ON_HINT))
  }

  @Test
  fun wording() {
    assertEquals("Hearth-rug is spelt H, E, A, R, T, H, hyphen, R, U, G.", AskWording.spell("hearth-rug"))
    assertEquals("Mr. Bennet", AskWording.spokenName("mr bennet"))
    assertEquals("the Time Machine", AskWording.spokenName("the time machine"))
    val long = (1..60).joinToString(" ") { "w$it" } + " Holmes " + (1..60).joinToString(" ") { "x$it" }
    val clipped = AskWording.clip(long, listOf("holmes"))
    assertTrue(clipped, clipped.contains("Holmes") && clipped.startsWith("... ") && clipped.endsWith(" ..."))
    assertTrue(Words.of(clipped).size <= 32)
  }
}
