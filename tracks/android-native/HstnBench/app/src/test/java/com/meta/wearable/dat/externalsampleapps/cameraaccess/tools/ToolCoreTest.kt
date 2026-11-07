// ToolCoreTest - launching a tool (launcher alias, extras, deep link), the recent-text store for
// "ask about the text", and the shared phrase helpers.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools

import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.LaunchIntent
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.Phrases
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.RecentText
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolLaunch
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolRequest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ToolCoreTest {

  @Test
  fun launcherAliasesOpenTheirTool() {
    val pkg = "com.meta.wearable.dat.externalsampleapps.cameraaccess"
    assertEquals(ToolRequest(ToolId.BOOK), ToolLaunch.parse(LaunchIntent(componentClass = "$pkg.BookReaderLauncher")))
    assertEquals(ToolRequest(ToolId.MAIL), ToolLaunch.parse(LaunchIntent(componentClass = "$pkg.MailReaderLauncher")))
    assertEquals(ToolRequest(ToolId.WATCH), ToolLaunch.parse(LaunchIntent(componentClass = "$pkg.WatchForTextLauncher")))
    assertEquals(ToolRequest(ToolId.LABELS), ToolLaunch.parse(LaunchIntent(componentClass = "$pkg.LabelReaderLauncher")))
    assertEquals(ToolRequest(ToolId.LIGHT), ToolLaunch.parse(LaunchIntent(componentClass = "$pkg.LightDetectorLauncher")))
    assertNull(ToolLaunch.parse(LaunchIntent(componentClass = "$pkg.MainActivity")))
  }

  @Test
  fun extrasAndDeepLinks() {
    assertEquals(ToolRequest(ToolId.MAIL), ToolLaunch.parse(LaunchIntent(toolExtra = "mail")))
    assertEquals(
        ToolRequest(ToolId.WATCH, argument = "42"),
        ToolLaunch.parse(LaunchIntent(toolExtra = "watch", argExtra = "42")),
    )
    assertEquals(ToolRequest(ToolId.BOOK), ToolLaunch.parse(LaunchIntent(bookReaderExtra = true)))
    assertEquals(ToolRequest(ToolId.BOOK), ToolLaunch.parse(LaunchIntent(scheme = "hstnbench", host = "book")))
    assertEquals(
        ToolRequest(ToolId.LIGHT, mode = "colour"),
        ToolLaunch.parse(LaunchIntent(scheme = "hstnbench", host = "light", queryMode = "colour")),
    )
    assertNull(ToolLaunch.parse(LaunchIntent(scheme = "https", host = "mail")))
    assertNull(ToolLaunch.parse(LaunchIntent(toolExtra = "nonsense")))
  }

  @Test
  fun recentTextKeepsPagesAndTheCurrentSentence() {
    var now = 1000L
    val store = RecentText(maxChars = 30, clock = { now })
    assertNull(store.forQuestion(ToolId.BOOK))
    store.addPassage(ToolId.BOOK, "Page one text.", key = "p1")
    store.addPassage(ToolId.BOOK, "Page two text.", key = "p2")
    store.setCurrent(ToolId.BOOK, "Page two text.")
    assertEquals(listOf("Page one text.", "Page two text."), store.snapshot(ToolId.BOOK)!!.passages)
    // Same key replaces; over the limit, the oldest goes.
    store.addPassage(ToolId.BOOK, "Page two, fixed.", key = "p2")
    store.addPassage(ToolId.BOOK, "Page three.", key = "p3")
    assertEquals(listOf("Page two, fixed.", "Page three."), store.snapshot(ToolId.BOOK)!!.passages)
    assertEquals("Page two text.", store.snapshot(ToolId.BOOK)!!.current)
    // No mail text: a question in the mail tool falls back to the latest tool's text.
    now = 2000L
    assertEquals(ToolId.BOOK, store.forQuestion(ToolId.MAIL)!!.tool)
    store.addPassage(ToolId.MAIL, "Dear Sir")
    assertEquals(ToolId.MAIL, store.forQuestion(ToolId.MAIL)!!.tool)
    store.clear(ToolId.MAIL)
    assertNull(store.snapshot(ToolId.MAIL))
  }

  @Test
  fun phrases() {
    assertEquals("watch for 42", Phrases.normalize("Glasses, um, watch for 42 please"))
    assertEquals("the right exit", Phrases.after(Regex("watch for"), "watch for the right exit please"))
    assertEquals(1.5f, Phrases.parseNumber("one and a half"))
    assertEquals(3, Phrases.wordCount(" a  b c "))
  }
}
