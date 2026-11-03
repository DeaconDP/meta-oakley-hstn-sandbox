package com.meta.wearable.dat.externalsampleapps.cameraaccess.book

import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.VoiceCommand.AutoTurn
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.VoiceCommand.Back
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.VoiceCommand.BackParagraph
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.VoiceCommand.Close
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.VoiceCommand.Faster
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.VoiceCommand.FromTop
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.VoiceCommand.Help
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.VoiceCommand.NextPage
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.VoiceCommand.Pause
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.VoiceCommand.ReadFurniture
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.VoiceCommand.Repeat
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.VoiceCommand.Resume
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.VoiceCommand.SetRate
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.VoiceCommand.Slower
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.VoiceCommand.WhereAmI
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class VoiceCommandsTest {

  private fun assertParses(expected: VoiceCommand, vararg phrases: String) {
    for (p in phrases) assertEquals("\"$p\"", expected, VoiceCommands.parse(p))
  }

  @Test
  fun pauseInManyWords() =
      assertParses(
          Pause,
          "Stop", "stop.", "Pause", "Wait!", "Hang on", "hold on a sec", "hang on a minute",
          "wait a second", "Shh", "be quiet", "one moment", "Reader, stop", "um, stop please",
          "Stop reading", "just a minute",
      )

  @Test
  fun resumeAndStart() =
      assertParses(
          Resume,
          "Read", "read to me", "Go on", "carry on", "Keep going", "continue", "Resume",
          "OK go", "I'm ready", "start reading", "Hey reader, keep reading please",
      )

  @Test
  fun nextPage() =
      assertParses(NextPage, "Next page", "I've turned the page", "turned", "page turned", "next one")

  @Test
  fun repeatAndBack() {
    assertParses(Repeat, "Say that again", "repeat", "again", "Pardon?", "What did it say?", "Sorry?",
        "I didn't catch that")
    assertParses(Back(1), "back", "go back", "Go back a sentence", "back a bit", "previous sentence")
    assertParses(Back(3), "go back three sentences", "back 3 sentences")
    assertParses(Back(2), "back two")
    assertParses(BackParagraph, "back a paragraph", "go back to the start of the paragraph",
        "read that paragraph again")
    assertParses(FromTop, "start the page again", "read the page again", "from the top",
        "read this page from the beginning")
  }

  @Test
  fun speed() {
    assertParses(Faster(), "faster", "a bit faster", "speed up", "Hurry up", "too slow")
    assertParses(Slower(), "slower", "a little slower", "slow down", "too fast")
    assertParses(Faster(VoiceCommand.BIG_STEP), "much faster", "a lot faster")
    assertParses(Slower(VoiceCommand.BIG_STEP), "way slower")
    assertParses(SetRate(1.5f), "speed one point five", "set the speed to 1.5", "1.5x",
        "one and a half times speed", "read at 1.5 times")
    assertParses(SetRate(2f), "double speed", "two times", "speed 2")
    assertParses(SetRate(0.5f), "half speed")
    assertParses(SetRate(1f), "normal speed", "back to normal speed", "reset the speed")
  }

  @Test
  fun settings() {
    assertParses(ReadFurniture(false), "don't read page numbers", "skip the headers",
        "stop reading page numbers and headers")
    assertParses(ReadFurniture(true), "read page numbers", "read the headers too")
    assertParses(AutoTurn(false), "stop detecting page turns", "I'll tell you when I turn the page",
        "auto turn off")
    assertParses(AutoTurn(true), "detect page turns", "automatic page turns on")
  }

  @Test
  fun questionsAndLeaving() {
    assertParses(WhereAmI, "Where am I?", "what page am I on", "how far have I got")
    assertParses(Help, "Help", "What can I say?", "what are the options")
    assertParses(VoiceCommand.Battery, "battery", "How's the battery?", "how much battery is left",
        "is the battery low")
    assertParses(Close, "close the book", "I'm done", "goodbye", "exit", "that's enough for today")
  }

  @Test
  fun chatterIsNotACommand() {
    for (p in listOf("", "what time is it", "the dog wants to go out", "I think he did it",
        "stopwatch", "readership", "turn right at the lights", "hello there")) {
      assertNull("\"$p\"", VoiceCommands.parse(p))
    }
  }

  @Test
  fun numbers() {
    assertEquals(1.5f, VoiceCommands.parseNumber("one point five")!!, 0.001f)
    assertEquals(2.5f, VoiceCommands.parseNumber("two and a half")!!, 0.001f)
    assertEquals(0.5f, VoiceCommands.parseNumber("half")!!, 0.001f)
    assertEquals(1.75f, VoiceCommands.parseNumber("1.75")!!, 0.001f)
    assertNull(VoiceCommands.parseNumber("lots"))
  }

  @Test
  fun bargeInIsPauseOnly() {
    assertTrue(VoiceCommands.isBargeIn("stop"))
    assertTrue(VoiceCommands.isBargeIn("hang on"))
    assertFalse(VoiceCommands.isBargeIn("go back"))
  }
}

class EchoGuardTest {

  @Test
  fun commandWordReadFromTheBookIsEchoWhileSpeaking() {
    val g = EchoGuard()
    g.spoke("\"Stop!\" cried Holmes, springing to his feet.", nowMs = 0)
    assertTrue(g.isEcho("stop", nowMs = 1_000))
    assertTrue(g.isEcho("cried Holmes springing", nowMs = 1_000))
    // Something the book didn't say gets through.
    assertFalse(g.isEcho("pause", nowMs = 1_000))
    assertFalse(g.isEcho("go back", nowMs = 1_000))
  }

  @Test
  fun longChunkStaysGuardedUntilItEnds() {
    val g = EchoGuard(tailMs = 2_000)
    g.spoke("He said we should wait for the morning train.", nowMs = 0)
    // Still speaking 20 s later (slow rate): still guarded, even a single word.
    assertTrue(g.isEcho("wait", nowMs = 20_000))
    g.finished(nowMs = 21_000)
    // Recogniser lag: a phrase arriving just after is still the book...
    assertTrue(g.isEcho("for the morning train", nowMs = 22_500))
    // ...but a short command right after is the user.
    assertFalse(g.isEcho("wait", nowMs = 21_500))
    assertFalse(g.isEcho("for the morning train", nowMs = 23_500))
  }

  @Test
  fun answeringAPromptIsHeard() {
    val g = EchoGuard()
    g.spoke("Book reader. Say read to start, or help at any time.", nowMs = 0)
    assertTrue(g.isEcho("read", nowMs = 1_000)) // still prompting
    g.finished(nowMs = 3_000)
    assertFalse(g.isEcho("read", nowMs = 3_800))
    assertFalse(g.isEcho("help", nowMs = 4_000))
    assertTrue(g.isEcho("or help at any time", nowMs = 3_800))
  }

  @Test
  fun toleratesOneMisheardWordInFour() {
    val g = EchoGuard()
    g.spoke("It was the best of times, it was the worst of times.", nowMs = 0)
    assertTrue(g.isEcho("it was the best of dimes it was", nowMs = 500))
    assertFalse(g.isEcho("it was a good day out today", nowMs = 500))
  }

  @Test
  fun newUtteranceEndsThePreviousOne() {
    val g = EchoGuard(tailMs = 2_000)
    g.spoke("Go on, said the inspector.", nowMs = 0)
    g.spoke("Faster.", nowMs = 5_000) // our own reply; implicitly ends the chunk at 5 s
    assertTrue(g.isEcho("go on said the", nowMs = 6_000))
    assertFalse(g.isEcho("go on", nowMs = 6_000))
    assertTrue(g.isEcho("faster", nowMs = 8_000)) // the reply is still playing
  }
}
