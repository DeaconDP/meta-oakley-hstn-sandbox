// MailGrammarTest - the mail reader's commands, LetterText's patterns, and that nothing here steals
// another tool's phrase
//
// Every phrase in the brief maps to its command; other tools' openers ("read the label", "read a
// book", "watch for 42") and global commands ("stop", "carry on", "close") are left alone, so the
// global grammar still gets them inside the mail reader.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.mail

import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.GlobalGrammar
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.Phrases
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class MailGrammarTest {

  private fun parse(t: String) = MailGrammar.parse(Phrases.normalize(t))

  @Test
  fun briefPhrases() {
    val cases =
        mapOf(
            "What is this letter?" to MailCommand.Summarise,
            "what's this letter about" to MailCommand.Summarise,
            "read" to MailCommand.Summarise,
            "read this please" to MailCommand.Summarise,
            "what does it say" to MailCommand.Summarise,
            "read it all" to MailCommand.ReadAll,
            "Read the whole letter" to MailCommand.ReadAll,
            "read every word" to MailCommand.ReadAll,
            "who's it from" to MailCommand.From,
            "who is this letter from" to MailCommand.From,
            "who sent this" to MailCommand.From,
            "who's it for" to MailCommand.For,
            "who is it addressed to" to MailCommand.For,
            "how much" to MailCommand.HowMuch,
            "how much do I owe" to MailCommand.HowMuch,
            "what's the amount due" to MailCommand.HowMuch,
            "when is it due" to MailCommand.WhenDue,
            "when do I have to pay" to MailCommand.WhenDue,
            "what's the deadline" to MailCommand.WhenDue,
            "is it junk" to MailCommand.IsJunk,
            "is this junk mail" to MailCommand.IsJunk,
            "is it important" to MailCommand.IsJunk,
            "is this a bill" to MailCommand.Kind,
            "what kind of letter is this" to MailCommand.Kind,
            "read the envelope" to MailCommand.Envelope,
            "next page" to MailCommand.NextPage,
            "there's another page" to MailCommand.NextPage,
            "I've turned it over" to MailCommand.NextPage,
            "new letter" to MailCommand.NewLetter,
            "next letter" to MailCommand.NewLetter,
            "what's the account number" to MailCommand.Reference,
            "what's the reference" to MailCommand.Reference,
            "what's the date on it" to MailCommand.Date,
            "go back" to MailCommand.Back,
            "back a sentence" to MailCommand.Back,
            "skip" to MailCommand.Skip,
            "next" to MailCommand.Skip,
            "start again" to MailCommand.StartAgain,
            "from the top" to MailCommand.StartAgain,
            "summary" to MailCommand.Summary,
            "tell me again" to MailCommand.Summary,
        )
    for ((phrase, command) in cases) assertEquals(phrase, command, parse(phrase))
  }

  @Test
  fun leavesOtherToolsAndGlobalCommandsAlone() {
    for (p in listOf(
        "read the label", "read a book", "open the book reader", "watch for 42", "scan this", "is the light on",
        "what colour is this", "stop", "carry on", "close", "say that again", "faster", "help", "battery",
        "what does Penang lawyer mean", "turn right at the lights", "my mail came late",
    )) {
      assertNull(p, parse(p))
    }
    // The global grammar still routes them.
    assertEquals(true, GlobalGrammar.parse("read the label") != null)
  }

  @Test
  fun money() {
    assertEquals(Money("£", 8417), LetterText.money("Amount due £84.17").single().money)
    assertEquals(Money("£", 168_400), LetterText.money("Amount payable £1,684.00").single().money)
    assertEquals(Money("€", 1250_00), LetterText.money("Total €1,250").single().money)
    assertEquals(Money("£", 1999), LetterText.money("You owe 19.99 GBP").single().money)
    assertEquals(Money("$", 500), LetterText.money("pay \$5, and").single().money)
    assertNull(LetterText.money("Amount due £8O.17").single().money)
    assertNull(LetterText.money("Amount due £l2.50").single().money)
    assertEquals(true, LetterText.money("Refund £12.30 CR").single().credit)
    assertEquals("£84.17", Money("£", 8417).spoken())
    assertEquals("£1,684", Money("£", 168_400).spoken())
    assertEquals(emptyList<MoneyToken>(), LetterText.money("39.9% EAR, 412 kWh"))
  }

  @Test
  fun dates() {
    fun one(t: String) = LetterText.dates(t).single().spoken()
    assertEquals("24 November 2026", one("Please pay by 24 November 2026."))
    assertEquals("24 November 2026", one("by 24th Nov 2026"))
    assertEquals("24 November 2026", one("November 24, 2026"))
    assertEquals("4 November 2026", one("Date: 04/11/2026"))
    assertEquals("6 November 2026", one("2026-11-06"))
    assertEquals(emptyList<LetterDate>(), LetterText.dates("1 October to 31 Octob 2026"))
  }

  @Test
  fun numbersForSpeech() {
    assertEquals("8 8 4 2, 1 9 3 7, 5 5", LetterText.spellOut("8842 1937 55"))
    assertEquals("A B, 1 2 3 4 5 6, C", LetterText.spellOut("AB 123456 C"))
    assertEquals("Call 0 8 0 0, 1 2 3, 4 5 6 7 now", LetterText.forSpeech("Call 0800 123 4567 now"))
    assertEquals("Ref 1 2 3 4 5 6 7 8.", LetterText.forSpeech("Ref 12345678."))
    // Money, years and short numbers are left for the voice to say normally.
    assertEquals("Pay £1,684.00 in 2026, 10 times.", LetterText.forSpeech("Pay £1,684.00 in 2026, 10 times."))
  }
}
