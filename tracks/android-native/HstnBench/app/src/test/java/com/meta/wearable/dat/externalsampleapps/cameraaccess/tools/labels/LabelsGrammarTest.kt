// LabelsGrammarTest - the label reader's commands, and that it leaves other tools' phrases alone
//
// Phrases go through Phrases.normalize first, as ToolHub does.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.labels

import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.GlobalCommand
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.GlobalGrammar
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.Phrases
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LabelsGrammarTest {

  private fun parse(s: String) = LabelsGrammar.parse(Phrases.normalize(s))

  private fun check(command: LabelsCommand, vararg phrases: String) {
    for (p in phrases) assertEquals(p, command, parse(p))
  }

  @Test
  fun scanAndLookUp() {
    check(LabelsCommand.Scan, "scan this", "Scan again", "what's this?", "what is that", "try again", "next one", "scan")
    check(LabelsCommand.LookUp, "look it up", "Look it up, please", "can you look that up", "search for it", "what product is it", "look up")
    check(LabelsCommand.StopScan, "stop scanning", "cancel", "never mind")
  }

  @Test
  fun readingTheLabel() {
    check(LabelsCommand.ReadLabel, "read the label", "read it", "read", "read the box", "what does it say", "read it to me")
    check(LabelsCommand.ReadAll, "read it all", "read everything", "read the whole label", "read the rest", "read all of it")
  }

  @Test
  fun quickJumps() {
    check(
        LabelsCommand.Expiry, "when does it expire", "best before", "what's the use by date", "is it out of date",
        "has it expired", "expiry date", "when does it go off", "what's the date on it", "sell by",
    )
    check(LabelsCommand.Cooking, "cooking instructions", "how do I cook it", "how do I heat this up", "microwave instructions", "how long in the oven")
    check(LabelsCommand.Ingredients, "ingredients", "what are the ingredients", "what's in it", "read the ingredients", "what is it made of")
    check(LabelsCommand.Name, "what is it", "what's it called", "say the name again")
  }

  @Test
  fun allergens() {
    check(LabelsCommand.Allergens(null), "allergens", "allergy advice", "what are the allergens", "any allergens", "does it contain any allergens")
    check(LabelsCommand.Allergens("nuts"), "does it contain nuts", "does it have nuts in it", "is there any nuts in it", "are there nuts in this", "any nuts in it")
    check(LabelsCommand.Allergens("gluten"), "is it gluten free", "is it gluten-free?", "does this contain gluten")
    check(LabelsCommand.Allergens("milk"), "does it have milk", "has it got milk in it")
  }

  @Test
  fun dosesAreAlwaysCaught() {
    check(
        LabelsCommand.Dose, "how many should I take", "what's the dose", "what is the dosage", "how often",
        "how many tablets can I have", "how much should I give", "when should I take it", "can I take another one",
        "directions for use", "how do I take it",
    )
  }

  @Test
  fun leavesOtherToolsAndGlobalCommandsAlone() {
    for (p in listOf(
        "read my mail", "watch for 42", "tell me when you see the exit", "what colour is this", "is the light on",
        "open the book reader", "back to my book", "battery", "help", "close", "faster", "say that again", "stop",
        "what does ephemeral mean",
    )) {
      assertNull(p, parse(p))
    }
    // ...and they still reach the global grammar from inside this tool.
    assertTrue(GlobalGrammar.parse("read my mail") is GlobalCommand.Open)
    assertEquals(GlobalCommand.Pause, GlobalGrammar.parse("stop"))
  }

  @Test
  fun openingPhrasesStillOpenTheTool() {
    for (p in listOf("scan this", "what's this product", "read the label", "scan the barcode", "open the label reader")) {
      val c = GlobalGrammar.parse(p)
      assertTrue(p, c is GlobalCommand.Open && c.request.tool == ToolId.LABELS)
    }
  }
}
