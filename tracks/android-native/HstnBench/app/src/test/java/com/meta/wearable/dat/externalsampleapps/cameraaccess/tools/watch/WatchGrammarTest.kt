// WatchGrammarTest - what the user can say inside Watch for text, and "find X" from any tool
//
// Commands inside the tool (stop, carry on, what are you watching for, where is it, watch for
// something else with and without a target, a new "watch for X", the alive tick), that they leave
// the global commands ("stop", "close", "help") and other tools' openers alone, and that the opener
// keeps working through GlobalGrammar, including the added "find Boots".

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.watch

import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.GlobalCommand
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.GlobalGrammar
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.Phrases
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolRequest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class WatchGrammarTest {

  private fun p(said: String) = WatchGrammar.parse(Phrases.normalize(said), Phrases.light(said))

  @Test
  fun stopAndCarryOn() {
    for (s in listOf("stop watching", "Stop looking for it", "cancel", "never mind", "forget it",
        "pause watching", "don't look any more", "stop watching for 42")) {
      assertEquals(s, WatchCommand.Stop, p(s))
    }
    for (s in listOf("carry on watching", "keep watching", "start watching again", "watch again", "resume watching")) {
      assertEquals(s, WatchCommand.Resume, p(s))
    }
  }

  @Test
  fun whatAndWhere() {
    for (s in listOf("what are you watching for", "What am I looking for?", "what's the target",
        "what did I ask you to look for")) {
      assertEquals(s, WatchCommand.WhatTarget, p(s))
    }
    for (s in listOf("where is it", "where", "where's 42", "Where was it?", "which side", "which way is it",
        "where did you see it", "where's platform 3")) {
      assertEquals(s, WatchCommand.Where, p(s))
    }
    // Questions that aren't about the sighting go elsewhere (the ask seam, or not understood).
    assertNull(p("where did he go"))
    assertNull(p("where am i"))
    assertNull(p("where are we"))
  }

  @Test
  fun newTargets() {
    assertEquals(WatchCommand.NewTarget("73"), p("watch for something else: 73"))
    assertEquals(WatchCommand.NewTarget("73"), p("watch for something else, 73"))
    assertEquals(WatchCommand.NewTarget(null), p("watch for something else"))
    assertEquals(WatchCommand.NewTarget("platform 4"), p("something else, platform 4"))
    assertEquals(WatchCommand.NewTarget("exit"), p("change it to exit"))
    assertEquals(WatchCommand.NewTarget("73"), p("now watch for 73 please"))
    assertEquals(WatchCommand.NewTarget("73"), p("watch for 73"))
    assertEquals(WatchCommand.NewTarget("right exit"), p("look out for the right exit"))
    assertEquals(WatchCommand.NewTarget("boots"), p("find Boots"))
  }

  @Test
  fun ticks() {
    assertEquals(WatchCommand.Ticks(0), p("ticks off"))
    assertEquals(WatchCommand.Ticks(0), p("turn off the ticking"))
    assertEquals(WatchCommand.Ticks(0), p("stop ticking"))
    assertEquals(WatchCommand.Ticks(0), p("no clicks"))
    assertEquals(WatchCommand.Ticks(null), p("ticks on"))
    assertEquals(WatchCommand.Ticks(null), p("turn the ticks back on"))
    assertEquals(WatchCommand.Ticks(20), p("tick every 20 seconds"))
    assertEquals(WatchCommand.Ticks(30), p("tick every thirty seconds"))
    assertEquals(WatchCommand.Ticks(5), p("ticks every five seconds"))
  }

  @Test
  fun globalCommandsAndOtherToolsAreLeftAlone() {
    for (s in listOf("stop", "close", "help", "say that again", "carry on", "battery", "faster",
        "read my mail", "open the book reader", "scan this", "is the light on", "what colour is this",
        "what does exit mean", "the bus is late again", "")) {
      assertNull(s, p(s))
    }
    assertEquals(GlobalCommand.Pause, GlobalGrammar.parse("stop"))
  }

  @Test
  fun findOpensWatchFromAnyTool() {
    assertEquals(GlobalCommand.Open(ToolRequest(ToolId.WATCH, argument = "boots")), GlobalGrammar.parse("find Boots"))
    assertEquals(GlobalCommand.Open(ToolRequest(ToolId.WATCH, argument = "exit")), GlobalGrammar.parse("find me the exit"))
    assertEquals(GlobalCommand.Open(ToolRequest(ToolId.WATCH, argument = "42")), GlobalGrammar.parse("watch for 42"))
    assertNull(GlobalGrammar.parse("find out what happened")?.let { it as? GlobalCommand.Open })
  }
}
