// AskGrammarTest - which phrases are questions about the text, and what kind
//
// Pins the phrasing for each kind, the gating of short follow-ups ("more", "next", "no"), phrases
// that must stay with other grammars (Repeat, the mail opener, Watch for text), and room chatter.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ask

import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.VoiceCommand
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.VoiceCommands
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.GlobalCommand
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.GlobalGrammar
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.Phrases
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class AskGrammarTest {

  private var now = 1_000_000L

  @Before
  fun setUp() {
    AskGrammar.FollowUps.clock = { now }
    AskGrammar.FollowUps.close()
  }

  @After
  fun tearDown() {
    AskGrammar.FollowUps.close()
    AskGrammar.FollowUps.clock = System::currentTimeMillis
  }

  private fun q(s: String) = AskGrammar.classify(Phrases.normalize(s))

  private fun assertKind(kind: AskKind, subject: String?, vararg phrases: String) {
    for (p in phrases) {
      val got = q(p)
      assertEquals(p, kind, got?.kind)
      assertEquals(p, subject, got?.subject)
    }
  }

  @Test
  fun definitions() {
    assertKind(AskKind.DEFINE, "ephemeral", "What does ephemeral mean?", "what does the word ephemeral mean",
        "define ephemeral", "Define the word ephemeral, please", "what's the meaning of ephemeral",
        "what is the definition of ephemeral", "look up ephemeral", "what's ephemeral again",
        "Glasses, what does ephemeral mean?", "um what does ephemeral mean again")
    assertKind(AskKind.DEFINE, "penang lawyer", "what does Penang lawyer mean")
    assertKind(AskKind.DEFINE, "hansom", "what's a hansom", "what is a hansom")
    assertKind(AskKind.DEFINE, "recon dight", "what does recon dight mean")
  }

  @Test
  fun spelling() {
    assertKind(AskKind.SPELL, null, "spell it", "spell that", "how do you spell it", "how is that spelt", "spell the word")
    assertKind(AskKind.SPELL, "recondite", "spell recondite", "how do you spell recondite", "how is recondite spelled")
  }

  @Test
  fun whoAndWhat() {
    assertKind(AskKind.WHO, "mr bennet", "Who is Mr. Bennet?", "who's Mr Bennet", "who was mr bennet again")
    assertKind(AskKind.WHO, "watson", "who's Watson?", "remind me who Watson is")
    assertKind(AskKind.WHAT, "time machine", "what's the Time Machine?", "what is the time machine")
    // Not about the text.
    for (p in listOf("what's the time", "what is the weather", "what's the date", "who is it from", "who's there",
        "what's the matter")) {
      assertNull(p, q(p))
    }
  }

  @Test
  fun recap() {
    for (p in listOf("what happened last time", "what happened before", "where did we leave off", "where were we",
        "where did I stop")) {
      val got = q(p)
      assertEquals(p, AskKind.RECAP, got?.kind)
      assertTrue(p, got!!.lastTime)
    }
    for (p in listOf("recap", "what happened", "give me a recap", "what happened so far", "remind me what happened",
        "summarise so far")) {
      assertEquals(p, AskKind.RECAP, q(p)?.kind)
    }
  }

  @Test
  fun finding() {
    assertKind(AskKind.FIND, "the fire", "what did it say about the fire", "what did the book say about the fire",
        "what does it say about the fire", "did it say anything about the fire", "find the fire",
        "search for the fire", "where does it mention the fire", "where was the fire mentioned")
    assertKind(AskKind.FIND, "holmes", "what did Holmes say")
    // "Find me ..." belongs to Watch for text.
    assertNull(q("find me the exit"))
    assertEquals(ToolId.WATCH, (GlobalGrammar.parse("find me the exit") as GlobalCommand.Open).request.tool)
  }

  @Test
  fun openQuestions() {
    for (p in listOf("why did he do that", "why is Holmes sitting with his back to me", "where did they go",
        "how did he know", "what did Filby want", "when did this happen", "does the letter say when it's due")) {
      assertEquals(p, AskKind.OPEN, q(p)?.kind)
    }
  }

  @Test
  fun followUpsOnlyCountAfterAnAnswerOffersThem() {
    for (p in listOf("more", "next", "tell me more", "no", "next match")) assertNull(p, q(p))
    AskGrammar.FollowUps.open(more = true, no = false)
    assertEquals(AskKind.MORE, q("more")?.kind)
    assertEquals(AskKind.MORE, q("next")?.kind)
    assertEquals(AskKind.MORE, q("other meanings")?.kind)
    assertNull("no wasn't offered", q("no"))
    AskGrammar.FollowUps.open(more = false, no = true)
    assertEquals(AskKind.NO, q("no, not that one")?.kind)
    assertEquals(AskKind.NO, q("the other one")?.kind)
    now += AskGrammar.FollowUps.WINDOW_MS + 1
    assertNull("expired", q("no"))
    // The partial-result barge-in never treats a follow-up as a question.
    AskGrammar.FollowUps.open(more = true, no = true)
    assertFalse(AskGrammar.isQuestion("more"))
    assertTrue(AskGrammar.isQuestion("what does recondite mean"))
    assertTrue(AskGrammar.isQuestion("who is Holmes"))
    assertFalse(AskGrammar.isQuestion("what does"))
  }

  @Test
  fun otherGrammarsKeepTheirPhrases() {
    assertEquals(GlobalCommand.Repeat, GlobalGrammar.parse("what did you say"))
    assertEquals(GlobalCommand.Repeat, GlobalGrammar.parse("what did it say"))
    assertEquals(ToolId.MAIL, (GlobalGrammar.parse("who is this letter from") as GlobalCommand.Open).request.tool)
    assertEquals(ToolId.LIGHT, (GlobalGrammar.parse("what colour is this") as GlobalCommand.Open).request.tool)
    assertEquals(GlobalCommand.Resume, GlobalGrammar.parse("carry on"))
    // Inside the book reader its own grammar goes first: these stay book commands...
    assertEquals(VoiceCommand.NextPage, VoiceCommands.parse("next one"))
    assertEquals(VoiceCommand.WhereAmI, VoiceCommands.parse("where are we"))
    assertEquals(VoiceCommand.Resume, VoiceCommands.parse("carry on"))
    // ...and questions and follow-ups aren't, so they reach the ask grammar.
    for (p in listOf("what does recondite mean", "who is holmes", "what did it say about the fire", "more", "next",
        "spell it", "no", "where did we leave off", "recap")) {
      assertNull(p, VoiceCommands.parse(p))
    }
    // The global grammar passes the subject through.
    val ask = GlobalGrammar.parse("What does recondite mean?") as GlobalCommand.Ask
    assertEquals("recondite", ask.subject)
  }

  @Test
  fun roomChatterIsNotAQuestion() {
    for (p in listOf("turn right at the lights", "I'll have a coffee", "it was a dark and stormy night",
        "more coffee please", "next stop is ours", "no idea", "the bus is late again today", "")) {
      assertNull(p, q(p))
    }
  }
}
