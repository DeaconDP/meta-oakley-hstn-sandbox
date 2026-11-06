// GlobalGrammarTest - the commands every tool understands, switching tools by voice, and questions
//
// The phrases in the ROADMAP / tools-layer brief must keep routing where they do: feature agents
// adding synonyms in their own grammar files run this to check they haven't stolen another tool's
// phrase. Room chatter must parse to nothing.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools

import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.VoiceCommand
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.VoiceCommands
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.GlobalCommand
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.GlobalGrammar
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolRequest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GlobalGrammarTest {

  private fun opens(text: String): ToolRequest? = (GlobalGrammar.parse(text) as? GlobalCommand.Open)?.request

  @Test
  fun mailPhrasesOpenTheMailReader() {
    for (p in listOf("read my mail", "What is this letter?", "what's this letter about", "check the post",
        "open the mail reader", "who is this letter from", "Glasses, read my mail please")) {
      assertEquals(p, ToolRequest(ToolId.MAIL), opens(p))
    }
  }

  @Test
  fun watchPhrasesCarryTheTarget() {
    assertEquals(ToolRequest(ToolId.WATCH, argument = "42"), opens("watch for 42"))
    assertEquals(ToolRequest(ToolId.WATCH, argument = "exit"), opens("Tell me when you see EXIT."))
    assertEquals(ToolRequest(ToolId.WATCH, argument = "platform 9"), opens("look out for platform 9 please"))
    // "right" is a filler elsewhere, but part of the target here.
    assertEquals(ToolRequest(ToolId.WATCH, argument = "right exit"), opens("watch for the right exit"))
    assertEquals(ToolRequest(ToolId.WATCH, argument = "room 12b"), opens("let me know when you see room 12B"))
    assertEquals(ToolRequest(ToolId.WATCH), opens("open watch for text"))
  }

  @Test
  fun labelPhrasesOpenTheLabelReader() {
    for (p in listOf("scan this", "what's this product", "read the label", "scan the barcode",
        "what is this tin", "open the label reader")) {
      assertEquals(p, ToolRequest(ToolId.LABELS), opens(p))
    }
  }

  @Test
  fun lightAndColourPhrases() {
    for (p in listOf("light detector", "is the light on", "are the lights on", "is it dark in here")) {
      assertEquals(p, ToolRequest(ToolId.LIGHT), opens(p))
    }
    val colour = ToolRequest(ToolId.LIGHT, mode = ToolRequest.MODE_COLOUR)
    for (p in listOf("what colour is this", "What color is this?", "what's the colour of this", "colour detector")) {
      assertEquals(p, colour, opens(p))
    }
  }

  @Test
  fun bookPhrasesOpenTheBookReader() {
    for (p in listOf("open the book reader", "read a book", "back to my book", "book reader")) {
      assertEquals(p, ToolRequest(ToolId.BOOK), opens(p))
    }
  }

  @Test
  fun everydayCommands() {
    assertEquals(GlobalCommand.Pause, GlobalGrammar.parse("stop"))
    assertEquals(GlobalCommand.Pause, GlobalGrammar.parse("hang on a sec"))
    assertEquals(GlobalCommand.Repeat, GlobalGrammar.parse("say that again"))
    assertEquals(GlobalCommand.Faster(), GlobalGrammar.parse("a bit faster"))
    assertEquals(GlobalCommand.Slower(GlobalCommand.BIG_STEP), GlobalGrammar.parse("much slower"))
    assertEquals(GlobalCommand.SetRate(1.5f), GlobalGrammar.parse("one and a half times speed"))
    assertEquals(GlobalCommand.SetRate(1f), GlobalGrammar.parse("normal speed"))
    assertEquals(GlobalCommand.Help, GlobalGrammar.parse("what can I say"))
    assertEquals(GlobalCommand.Battery, GlobalGrammar.parse("how's the battery"))
    assertEquals(GlobalCommand.Close, GlobalGrammar.parse("close the mail reader"))
    assertEquals(GlobalCommand.Close, GlobalGrammar.parse("goodbye"))
    assertEquals(GlobalCommand.Resume, GlobalGrammar.parse("carry on"))
    assertTrue(GlobalGrammar.isBargeIn("Stop."))
  }

  @Test
  fun questionsAboutTheTextGoToAsk() {
    val ask = GlobalGrammar.parse("What does ephemeral mean?") as GlobalCommand.Ask
    assertEquals("ephemeral", ask.subject)
    assertEquals("What does ephemeral mean?", ask.question)
    assertEquals("mr bennet", (GlobalGrammar.parse("Who's Mr. Bennet?") as GlobalCommand.Ask).subject)
    assertTrue(GlobalGrammar.parse("what happened last time") is GlobalCommand.Ask)
    assertTrue(GlobalGrammar.parse("what's the meaning of conflagration") is GlobalCommand.Ask)
    // Not questions about the text.
    assertEquals(GlobalCommand.Repeat, GlobalGrammar.parse("what did you say"))
    assertEquals(ToolRequest(ToolId.MAIL), opens("who is this letter from"))
  }

  @Test
  fun roomChatterIsNothing() {
    for (p in listOf("turn right at the lights", "I'll have a coffee", "the bus is late again today",
        "stopwatch", "my mail came late", "it was a dark and stormy night", "")) {
      assertNull(p, GlobalGrammar.parse(p))
    }
  }

  @Test
  fun theBookGrammarStillWinsInsideTheBookReader() {
    // The book reader tries its own grammar first: these keep their book meaning.
    assertEquals(VoiceCommand.Resume, VoiceCommands.parse("read the book"))
    assertEquals(VoiceCommand.WhereAmI, VoiceCommands.parse("where am I"))
    // ...and these aren't book commands, so the global grammar gets them.
    for (p in listOf("read my mail", "watch for 42", "scan this", "is the light on", "what colour is this",
        "what does ephemeral mean")) {
      assertNull(p, VoiceCommands.parse(p))
    }
  }
}
