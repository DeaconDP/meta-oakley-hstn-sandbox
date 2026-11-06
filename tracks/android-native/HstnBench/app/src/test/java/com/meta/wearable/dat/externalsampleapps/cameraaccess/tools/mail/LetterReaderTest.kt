// LetterReaderTest - the mail reader's rules on realistic letters (LetterFixtures)
//
// Sender, recipient, kind, date, subject, amount due and deadline for a utility bill, a bank
// letter, a council tax bill, a personal letter, a flyer, a window envelope, a hospital
// appointment and a two-page bill; and the money rule: a smudged digit, a letter where a digit
// should be, or two different amounts due, and no figure is ever spoken.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.mail

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LetterReaderTest {

  private fun read(vararg scans: LetterScan) = LetterReader.read(scans.toList())

  @Test
  fun utilityBill() {
    val l = read(LetterFixtures.utilityBill())
    assertFalse(l.isEnvelope)
    assertEquals(LetterKind.BILL, l.kind)
    assertEquals("Northgate Energy", l.sender)
    assertEquals("Mrs Jane Patel", l.recipient)
    assertEquals("14 Elm Road, Leeds, LS6 2AB", l.recipientAddress)
    assertEquals("Mrs Patel", l.salutation)
    assertEquals("3 November 2026", l.date?.spoken())
    assertEquals("Your electricity bill", l.subject)
    assertEquals(AmountDue.Sure(Money("£", 8417)), l.amount)
    assertEquals(DueDate(DueKind.PAY, "24 November 2026", true), l.due)
    assertEquals("account number", l.references.first().label)
    assertEquals("account number 8 8 4 2, 1 9 3 7, 5 5", l.references.first().spoken)

    val s = LetterSpeech.summary(l)
    assertEquals(
        "A bill from Northgate Energy, for Mrs Jane Patel. Dated 3 November 2026. About: Your electricity bill. " +
            "Amount due: £84.17, by 24 November 2026. Say read it all to hear every word.",
        s,
    )
    assertEquals("The amount due is £84.17. Pay by 24 November 2026.", LetterSpeech.howMuch(l))
    assertEquals("It doesn't look like junk. It's a bill.", LetterSpeech.isJunk(l))
  }

  @Test
  fun utilityBillReadsTheTableAsRowsInOrder() {
    val text = read(LetterFixtures.utilityBill()).fullText
    assertTrue(text, text.contains("Standing charge £12.30"))
    assertTrue(text, text.contains("Energy used (412 kWh) £71.87"))
    assertTrue(text, text.contains("Amount due £84.17"))
    // Letterhead, then the address as one sentence, then the paragraphs.
    assertTrue(text.indexOf("Northgate Energy") < text.indexOf("Mrs Jane Patel, 14 Elm Road, Leeds, LS6 2AB."))
    assertTrue(text.indexOf("Dear Mrs Patel") < text.indexOf("Here is your bill"))
    assertTrue(text.indexOf("Standing charge") < text.indexOf("Yours sincerely"))
    // The paragraph's lines are joined into one.
    assertTrue(text, text.contains("31 October 2026. Your Direct Debit is not set up"))
  }

  @Test
  fun bankLetter() {
    val l = read(LetterFixtures.bankLetter)
    assertEquals(LetterKind.BANK, l.kind)
    assertEquals("Harbour Bank", l.sender)
    assertEquals("Mr Tom Reid", l.recipient)
    assertEquals("Changes to your current account", l.subject)
    assertEquals("28 October 2026", l.date?.spoken())
    // A balance isn't an amount due.
    assertEquals(AmountDue.None, l.amount)
    assertEquals(
        "I can't see an amount to pay. The letter mentions one amount; say read it all to hear them.",
        LetterSpeech.howMuch(l),
    )
    assertTrue(l.references.any { it.label == "sort code" && it.value == "20-45-77" })
    assertTrue(l.references.any { it.label == "account ending" && it.value == "4471" })
  }

  @Test
  fun councilTaxBill() {
    val l = read(LetterFixtures.councilTax)
    assertEquals(LetterKind.OFFICIAL, l.kind)
    assertEquals("Riverside Borough Council", l.sender)
    assertEquals("Mr Ahmed Khan", l.recipient)
    assertEquals("1 November 2026", l.date?.spoken())
    assertEquals("Council Tax Bill 2026/27", l.subject)
    assertEquals(AmountDue.Sure(Money("£", 168_400)), l.amount)
    assertEquals(DueDate(DueKind.PAY, "1 December 2026", true), l.due)
    assertEquals("council tax reference 6 0 0 3, 4 4 7 1, 2", l.references.first().spoken)
    assertTrue(LetterSpeech.summary(l).startsWith("An official letter from Riverside Borough Council, for Mr Ahmed Khan."))
    assertTrue(LetterSpeech.summary(l).contains("Amount due: £1,684, by 1 December 2026."))
  }

  @Test
  fun personalLetter() {
    val l = read(LetterFixtures.personal)
    assertEquals(LetterKind.PERSONAL, l.kind)
    assertEquals("Margaret", l.sender)
    // The address top right is the sender's, not the recipient's.
    assertNull(l.recipient)
    assertEquals("Jane", l.salutation)
    assertEquals("2 November 2026", l.date?.spoken())
    assertEquals(AmountDue.None, l.amount)
    val s = LetterSpeech.summary(l)
    assertTrue(s, s.startsWith("A personal letter from Margaret, for Jane. Dated 2 November 2026. It starts: I hope you are well"))
  }

  @Test
  fun flyerIsJunk() {
    val l = read(LetterFixtures.flyer)
    assertEquals(LetterKind.ADVERT, l.kind)
    assertFalse("an addressed flyer isn't an envelope", l.isEnvelope)
    assertEquals("The Occupier", l.recipient)
    assertEquals("It looks like an advert, so probably junk mail.", LetterSpeech.isJunk(l))
  }

  @Test
  fun windowEnvelope() {
    val l = read(LetterFixtures.windowEnvelope)
    assertTrue(l.isEnvelope)
    assertEquals("Mrs Jane Patel", l.recipient)
    assertEquals("Northgate Energy", l.sender)
    assertEquals(
        "This is the outside of an envelope, addressed to Mrs Jane Patel, 14 Elm Road, Leeds, LS6 2AB, from Northgate Energy. " +
            "Open it and hold up the letter, then say read.",
        LetterSpeech.summary(l),
    )
  }

  @Test
  fun hospitalAppointment() {
    val l = read(LetterFixtures.appointment)
    assertEquals(LetterKind.MEDICAL, l.kind)
    assertEquals("Leeds Teaching Hospitals NHS Trust", l.sender)
    assertEquals("Ms Rosa Lind", l.recipient)
    assertEquals("30 October 2026", l.date?.spoken())
    assertEquals(DueDate(DueKind.APPOINTMENT, "8 December 2026 at 10:30am", true), l.due)
    assertTrue(LetterSpeech.summary(l).contains("Appointment: 8 December 2026 at 10:30am."))
    assertEquals("NHS number 4 8 5, 7 7 7, 3 4 5 6.", LetterSpeech.references(l))
  }

  @Test
  fun secondPageAddsTheAmountAndKeepsTheHeader() {
    val one = read(LetterFixtures.billPageOneNoAmount)
    assertEquals(AmountDue.None, one.amount)
    val both = read(LetterFixtures.billPageOneNoAmount, LetterFixtures.billPageTwo)
    assertEquals("Northgate Energy", both.sender)
    assertEquals("Mrs Jane Patel", both.recipient)
    assertEquals(AmountDue.Sure(Money("£", 8417)), both.amount)
    assertEquals("24 November 2026", both.due?.spoken)
    assertTrue(LetterSpeech.summary(both).startsWith("2 pages. A bill from Northgate Energy"))
    assertTrue(both.paragraphs.contains("Page 2."))
  }

  // MARK: - The money rule

  @Test
  fun lowConfidenceDigitMeansNoFigure() {
    // "£84.17" with the 4 smudged (confidence 0.3).
    val l = read(LetterFixtures.utilityBill(amountLow = mapOf(2 to 0.3f)))
    assertEquals(AmountDue.Unsure, l.amount)
    val s = LetterSpeech.summary(l)
    assertTrue(s, s.contains(LetterSpeech.UNSURE_AMOUNT))
    assertFalse(s, s.contains("84"))
    assertFalse(LetterSpeech.howMuch(l).contains("84"))
    assertTrue(LetterSpeech.howMuch(l).startsWith("I can't read the amount for sure"))
    // Reading it all doesn't say the figure either, but still says the sure ones.
    val reading = l.readingParagraphs.joinToString(" ")
    assertFalse(reading, reading.contains("£84.17"))
    assertTrue(reading, reading.contains("Amount due an amount I can't read for sure"))
    assertTrue(reading, reading.contains("£12.30"))
  }

  @Test
  fun aLetterWhereADigitShouldBeMeansNoFigure() {
    val l = read(LetterFixtures.utilityBill(amountDue = "£8O.17"))
    assertEquals(AmountDue.Unsure, l.amount)
    assertFalse(LetterSpeech.summary(l).contains("8O"))
  }

  @Test
  fun twoDifferentAmountsDueConflict() {
    val l = read(LetterFixtures.utilityBill(secondTotal = "£48.17"))
    assertEquals(AmountDue.Conflict, l.amount)
    val s = LetterSpeech.summary(l)
    assertTrue(s.contains(LetterSpeech.CONFLICTING_AMOUNTS))
    assertFalse(s, s.contains("84.17") || s.contains("48.17"))
  }

  @Test
  fun theSameAmountTwiceIsFine() {
    val l = read(LetterFixtures.utilityBill(secondTotal = "£84.17"))
    assertEquals(AmountDue.Sure(Money("£", 8417)), l.amount)
  }

  @Test
  fun lowConfidenceInTheLabelDoesNotMatter() {
    // Only the digits of the amount count: a smudged "£" sign or word next to it doesn't.
    val l = read(LetterFixtures.utilityBill(amountLow = mapOf(0 to 0.2f)))
    assertEquals(AmountDue.Sure(Money("£", 8417)), l.amount)
  }

  @Test
  fun lineConfidenceOnlyIsUsedWhenThatIsAllThereIs() {
    val scan = letter {
      block { line("Amount due £20.00", 80f, 100f) }
    }
    val noWords = scan.copy(lines = scan.lines.map { it.copy(words = emptyList(), confidence = 0.4f) })
    assertEquals(AmountDue.Unsure, LetterReader.read(listOf(noWords)).amount)
    val sure = scan.copy(lines = scan.lines.map { it.copy(words = emptyList(), confidence = 0.9f) })
    assertEquals(AmountDue.Sure(Money("£", 2000)), LetterReader.read(listOf(sure)).amount)
  }

  @Test
  fun minimumPaymentIsNotAConflict() {
    val scan = letter {
      block { line("Harbour Bank Credit Card", 80f, 70f, h = 48f) }
      block {
        line("Statement balance £1,234.56", 80f, 400f)
        line("Minimum payment £25.00", 80f, 432f)
        line("Payment due date: 18 December 2026", 80f, 464f)
      }
    }
    val l = LetterReader.read(listOf(scan))
    assertEquals(AmountDue.Sure(Money("£", 123_456), minimum = Money("£", 2500)), l.amount)
    assertEquals("18 December 2026", l.due?.spoken)
  }
}
