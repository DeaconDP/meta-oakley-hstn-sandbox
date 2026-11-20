// GlobalGrammarTest - the commands every tool understands, switching tools by voice, and questions
//
// The phrases in the ROADMAP / tools-layer brief must keep routing where they do: feature agents
// adding synonyms in their own grammar files run this to check they haven't stolen another tool's
// phrase. Room chatter must parse to nothing.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools

import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.VoiceCommand
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.VoiceCommands
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.CameraSource
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.GlobalCommand
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.GlobalGrammar
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolRequest
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.Verbosity
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
  fun mainMenuPhrasesGoHome() {
    for (p in listOf("main menu", "Main menu, please", "menu", "go home", "home", "back to menu",
        "back to the main menu", "go back to the menu", "take me home", "open the menu", "go back home",
        "Glasses, main menu")) {
      assertEquals(p, GlobalCommand.Home, GlobalGrammar.parse(p))
      assertEquals(p, GlobalCommand.Home, GlobalGrammar.parseHome(p))
    }
  }

  @Test
  fun closeTheAppLeavesTheApp() {
    for (p in listOf("close the app", "exit app", "quit the app", "Exit the application", "close this app",
        "shut down the app", "close everything")) {
      assertEquals(p, GlobalCommand.ExitApp, GlobalGrammar.parse(p))
    }
    // Plain close still means "close this tool" (in the menu ToolHub takes it as leaving the app).
    for (p in listOf("close", "exit", "goodbye", "quit", "close the book reader", "I'm done")) {
      assertEquals(p, GlobalCommand.Close, GlobalGrammar.parse(p))
      assertEquals(p, GlobalCommand.Close, GlobalGrammar.parseHome(p))
    }
  }

  @Test
  fun theHomeMenuAlsoTakesBareToolNames() {
    val home = { p: String -> (GlobalGrammar.parseHome(p) as? GlobalCommand.Open)?.request }
    // What the welcome offers, word for word.
    assertEquals(ToolRequest(ToolId.BOOK), home("read my book"))
    assertEquals(ToolRequest(ToolId.MAIL), home("read my mail"))
    assertEquals(ToolRequest(ToolId.LABELS), home("labels"))
    assertEquals(ToolRequest(ToolId.WATCH), home("watch for text"))
    assertEquals(ToolRequest(ToolId.LIGHT), home("light"))
    assertEquals(GlobalCommand.Help, GlobalGrammar.parseHome("what can I say"))
    // Short names, only in the menu.
    assertEquals(ToolRequest(ToolId.BOOK), home("book"))
    assertEquals(ToolRequest(ToolId.MAIL), home("letters"))
    assertEquals(ToolRequest(ToolId.WATCH), home("watch"))
    assertEquals(ToolRequest(ToolId.LIGHT, mode = ToolRequest.MODE_COLOUR), home("colour"))
    assertEquals(ToolRequest(ToolId.LABELS), home("barcode"))
    for (p in listOf("light", "book", "colour", "watch", "letters", "barcode")) assertNull(p, GlobalGrammar.parse(p))
    // The full phrases still carry their arguments.
    assertEquals(ToolRequest(ToolId.WATCH, argument = "42"), home("watch for 42"))
    assertEquals(GlobalCommand.Resume, GlobalGrammar.parseHome("start"))
    assertEquals(GlobalCommand.Battery, GlobalGrammar.parseHome("battery"))
    for (p in listOf("turn right at the lights", "the bus is late again today", "")) assertNull(p, GlobalGrammar.parseHome(p))
  }

  @Test
  fun newGlobalPhrasesDontClashWithToolGrammars() {
    // Tool grammars run first: none of them may claim the menu or exit phrases.
    for (p in listOf("main menu", "go home", "home", "back to menu", "close the app", "exit app")) {
      assertNull("book: $p", VoiceCommands.parse(p))
      val n = com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.Phrases.normalize(p)
      assertNull("mail: $p", com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.mail.MailGrammar.parse(n))
      assertNull("watch: $p", com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.watch.WatchGrammar.parse(n, n))
      assertNull("labels: $p", com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.labels.LabelsGrammar.parse(n))
      assertNull("light: $p", com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.light.LightGrammar.parse(n))
    }
    // The book reader's own "close" still works inside it.
    assertEquals(VoiceCommand.Close, VoiceCommands.parse("close the book"))
    assertEquals(VoiceCommand.Close, VoiceCommands.parse("goodbye"))
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

  // MARK: - Hands-free mode (notes/hands-free-mode.md > What hands-free covers)

  @Test
  fun handsFreeOnAndOff() {
    for (p in listOf("hands-free on", "Hands free on", "handsfree on", "start hands-free", "turn on hands-free",
        "switch hands free on", "voice mode", "hands-free mode", "go hands free", "Glasses, hands-free on please")) {
      assertEquals(p, GlobalCommand.HandsFree(true), GlobalGrammar.parse(p))
      assertEquals(p, GlobalCommand.HandsFree(true), GlobalGrammar.parseHome(p))
      assertEquals(p, GlobalCommand.HandsFree(true), GlobalGrammar.parseMode(p))
    }
    for (p in listOf("hands-free off", "hands free off", "turn off hands-free", "stop hands free", "touch mode",
        "stop listening for good", "go back to touch", "touch only mode")) {
      assertEquals(p, GlobalCommand.HandsFree(false), GlobalGrammar.parse(p))
      assertEquals(p, GlobalCommand.HandsFree(false), GlobalGrammar.parseMode(p))
    }
    // Only the mode phrases for the setup screen.
    for (p in listOf("connect", "help", "stop", "main menu", "")) assertNull(p, GlobalGrammar.parseMode(p))
  }

  @Test
  fun navigationPhrases() {
    for (p in listOf("what tools are there", "list tools", "list the tools", "which tools do you have",
        "what can this app do", "tools", "tell me the tools")) {
      assertEquals(p, GlobalCommand.ListTools, GlobalGrammar.parse(p))
    }
    for (p in listOf("where am I", "Where am I?", "what screen is this", "which tool is this", "what's open")) {
      assertEquals(p, GlobalCommand.WhereAmI, GlobalGrammar.parse(p))
    }
    for (p in listOf("back", "go back", "previous screen")) {
      assertEquals(p, GlobalCommand.Back, GlobalGrammar.parse(p))
      assertEquals(p, GlobalCommand.Back, GlobalGrammar.parseHome(p))
    }
    // The menu phrases with "back" in them still go home.
    for (p in listOf("go back home", "back to menu", "go back to the menu")) {
      assertEquals(p, GlobalCommand.Home, GlobalGrammar.parse(p))
    }
  }

  @Test
  fun connectionPhrases() {
    for (p in listOf("connect", "connect my glasses", "reconnect", "connect to the glasses", "start the session",
        "turn on the camera")) {
      assertEquals(p, GlobalCommand.Connect, GlobalGrammar.parse(p))
    }
    for (p in listOf("disconnect", "disconnect my glasses", "end the session", "stop the camera", "turn off the camera")) {
      assertEquals(p, GlobalCommand.Disconnect, GlobalGrammar.parse(p))
    }
    for (p in listOf("status", "what's the status", "connection status", "are my glasses connected", "am I connected")) {
      assertEquals(p, GlobalCommand.Status, GlobalGrammar.parse(p))
    }
    // "End the app" is still leaving the app, not ending the session.
    assertEquals(GlobalCommand.ExitApp, GlobalGrammar.parse("close the app"))
  }

  @Test
  fun settingsPhrases() {
    assertEquals(GlobalCommand.Settings, GlobalGrammar.parse("settings"))
    assertEquals(GlobalCommand.Settings, GlobalGrammar.parse("what are my settings"))
    for (p in listOf("short answers", "shorter answers", "give me short answers", "be brief", "keep it short")) {
      assertEquals(p, GlobalCommand.SetVerbosity(Verbosity.SHORT), GlobalGrammar.parse(p))
    }
    for (p in listOf("normal answers", "regular answers")) {
      assertEquals(p, GlobalCommand.SetVerbosity(Verbosity.NORMAL), GlobalGrammar.parse(p))
    }
    for (p in listOf("detailed answers", "long answers", "more detail")) {
      assertEquals(p, GlobalCommand.SetVerbosity(Verbosity.DETAILED), GlobalGrammar.parse(p))
    }
    for (p in listOf("glasses display off", "turn off the glasses display", "display off", "stop showing it on my glasses")) {
      assertEquals(p, GlobalCommand.GlassesDisplay(false), GlobalGrammar.parse(p))
    }
    for (p in listOf("glasses display on", "turn on the glasses display", "display on", "show it on my glasses")) {
      assertEquals(p, GlobalCommand.GlassesDisplay(true), GlobalGrammar.parse(p))
    }
    // Speed stays where it was.
    assertEquals(GlobalCommand.Faster(), GlobalGrammar.parse("faster"))
    assertEquals(GlobalCommand.Slower(), GlobalGrammar.parse("slower"))
  }

  @Test
  fun theEverydayCommandsKeepTheirMeaning() {
    assertEquals(GlobalCommand.Pause, GlobalGrammar.parse("stop"))
    assertEquals(GlobalCommand.Pause, GlobalGrammar.parse("stop talking"))
    assertEquals(GlobalCommand.Resume, GlobalGrammar.parse("carry on"))
    assertEquals(GlobalCommand.Repeat, GlobalGrammar.parse("say that again"))
    assertEquals(GlobalCommand.Help, GlobalGrammar.parse("what can I say"))
    assertEquals(GlobalCommand.Close, GlobalGrammar.parse("close"))
    assertEquals(GlobalCommand.Battery, GlobalGrammar.parse("battery"))
    // Room chatter with the new words in it is still nothing.
    for (p in listOf("I left my glasses at home", "the display at the station was broken", "my status update",
        "we went back to the shop", "the session ran late")) {
      assertNull(p, GlobalGrammar.parse(p))
    }
  }

  @Test
  fun handsFreePhrasesDontClashWithToolGrammars() {
    // Tool grammars run first. None may claim these, except the book reader's own "where am I",
    // "back" and "status" (it answers them about the book), checked below.
    val phrases = listOf("hands-free on", "hands-free off", "voice mode", "touch mode", "stop listening for good",
        "what tools are there", "list tools", "connect", "disconnect", "settings", "short answers",
        "detailed answers", "glasses display off", "glasses display on")
    for (p in phrases) {
      assertNull("book: $p", VoiceCommands.parse(p))
      val n = com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.Phrases.normalize(p)
      assertNull("mail: $p", com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.mail.MailGrammar.parse(n))
      assertNull("watch: $p", com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.watch.WatchGrammar.parse(n, n))
      assertNull("labels: $p", com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.labels.LabelsGrammar.parse(n))
      assertNull("light: $p", com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.light.LightGrammar.parse(n))
      // ...and none of them opens a tool.
      assertTrue(p, GlobalGrammar.parse(p) !is GlobalCommand.Open)
    }
    assertEquals(VoiceCommand.WhereAmI, VoiceCommands.parse("where am I"))
    assertEquals(VoiceCommand.WhereAmI, VoiceCommands.parse("status"))
  }

  // MARK: - Glasses optional (notes/phone-camera.md)

  @Test
  fun cameraSwitchPhrases() {
    val phone = GlobalCommand.UseCamera(CameraSource.PHONE)
    for (p in listOf("use the phone", "Use the phone camera", "use my phone", "switch to the phone", "phone camera",
        "use the phone's camera", "use the phone instead", "Glasses, use the phone")) {
      assertEquals(p, phone, GlobalGrammar.parse(p))
      assertEquals(p, phone, GlobalGrammar.parseHome(p))
    }
    val glasses = GlobalCommand.UseCamera(CameraSource.GLASSES)
    for (p in listOf("use the glasses", "use my glasses", "switch to the glasses", "switch back to the glasses",
        "use the glasses camera", "use the glasses instead")) {
      assertEquals(p, glasses, GlobalGrammar.parse(p))
    }
    for (p in listOf("which camera", "Which camera?", "what camera are you using", "which camera is on",
        "is it the phone or the glasses")) {
      assertEquals(p, GlobalCommand.WhichCamera, GlobalGrammar.parse(p))
    }
    for (p in listOf("torch on", "turn on the torch", "turn the torch on", "flashlight on", "switch on the flashlight")) {
      assertEquals(p, GlobalCommand.Torch(true), GlobalGrammar.parse(p))
    }
    for (p in listOf("torch off", "turn off the torch", "turn the torch off", "flashlight off")) {
      assertEquals(p, GlobalCommand.Torch(false), GlobalGrammar.parse(p))
    }
  }

  @Test
  fun cameraPhrasesDontClashWithOtherPhrases() {
    val phrases = listOf("use the phone", "use the phone camera", "use the glasses", "which camera", "torch on", "torch off")
    for (p in phrases) {
      // Tool grammars run first: none may claim them, and none of them opens a tool.
      assertNull("book: $p", VoiceCommands.parse(p))
      val n = com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.Phrases.normalize(p)
      assertNull("mail: $p", com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.mail.MailGrammar.parse(n))
      assertNull("watch: $p", com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.watch.WatchGrammar.parse(n, n))
      assertNull("labels: $p", com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.labels.LabelsGrammar.parse(n))
      assertNull("light: $p", com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.light.LightGrammar.parse(n))
      assertTrue(p, GlobalGrammar.parse(p) !is GlobalCommand.Open)
      assertNull("setup mode: $p", GlobalGrammar.parseMode(p))
    }
    // The old phrases keep their meaning.
    assertEquals(GlobalCommand.Connect, GlobalGrammar.parse("turn on the camera"))
    assertEquals(GlobalCommand.Connect, GlobalGrammar.parse("connect my glasses"))
    assertEquals(GlobalCommand.Disconnect, GlobalGrammar.parse("turn off the camera"))
    assertEquals(GlobalCommand.Status, GlobalGrammar.parse("are my glasses connected"))
    assertEquals(GlobalCommand.HandsFree(true), GlobalGrammar.parse("use hands-free"))
    // A question about a torch in view is the light tool's, never the phone torch.
    assertTrue(GlobalGrammar.parse("is the torch on") !is GlobalCommand.Torch)
    // Chatter with the new words is still nothing.
    for (p in listOf("my phone is in my bag", "the glasses are on the table", "I need a torch for the garden",
        "the camera was expensive")) {
      assertNull(p, GlobalGrammar.parse(p))
    }
  }
}
