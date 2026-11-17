package com.meta.wearable.dat.externalsampleapps.cameraaccess.setup

import com.meta.wearable.dat.externalsampleapps.cameraaccess.setup.SetupCommand.CONNECT
import com.meta.wearable.dat.externalsampleapps.cameraaccess.setup.SetupCommand.DECLINE
import com.meta.wearable.dat.externalsampleapps.cameraaccess.setup.SetupCommand.HELP
import com.meta.wearable.dat.externalsampleapps.cameraaccess.setup.SetupCommand.OPEN_SETTINGS
import com.meta.wearable.dat.externalsampleapps.cameraaccess.setup.SetupCommand.QUIT
import com.meta.wearable.dat.externalsampleapps.cameraaccess.setup.SetupCommand.REPEAT
import org.junit.Assert.assertEquals
import org.junit.Test

class SetupGrammarTest {

  private fun check(expected: SetupCommand?, vararg phrases: String) {
    for (p in phrases) assertEquals("\"$p\"", expected, SetupGrammar.parse(p))
  }

  @Test
  fun connectPhrases() {
    check(
        CONNECT,
        "connect",
        "Connect.",
        "connect my glasses",
        "set up",
        "setup",
        "set it up please",
        "yes",
        "Yes please",
        "yeah",
        "sure",
        "start",
        "let's start",
        "register",
        "pair my glasses",
        "OK, connect",
        "um, connect please",
        "glasses, connect",
        "go ahead",
        "help me connect",
        "how do I connect",
        "try again",
        "retry",
    )
  }

  @Test
  fun negatedConnectIsADecline() {
    check(
        DECLINE,
        "don't connect",
        "Don't connect.",
        "do not connect",
        "no, don't set it up",
        "not now",
        "no",
        "No thanks",
        "nope",
        "later",
        "maybe later",
        "cancel",
        "never mind",
        "I don't want to connect",
        "don't start",
        "please don't register",
        "don't close",
        "do not quit",
    )
  }

  @Test
  fun wordsInsideOtherWordsDontCount() {
    check(null, "disconnect", "connected", "restart", "settle down", "registered mail")
  }

  @Test
  fun helpRepeatSettingsQuit() {
    check(HELP, "help", "what can I say", "What do I do?", "where am I", "options", "how does this work")
    check(REPEAT, "repeat", "say that again", "pardon", "what did you say", "again please", "sorry what")
    check(OPEN_SETTINGS, "open settings", "settings", "app permissions", "go to settings")
    check(QUIT, "quit", "close the app", "close", "exit", "goodbye", "I'm done", "leave the app")
  }

  @Test
  fun roomChatterIsNothing() {
    check(
        null,
        "",
        "   ",
        "what's for dinner",
        "the kettle's boiling",
        "I'll start dinner when the football is over tonight",
        "can you pass me the remote control from the table",
        "close the door behind you when you leave the kitchen please",
    )
  }
}
