// LabelDatesTest - best-before, use-by and expiry dates in the formats labels print them
//
// "Today" is fixed at 6 November 2026 so dates with no year and "already passed" are stable.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.labels

import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LabelDatesTest {

  private val today = LocalDate.of(2026, 11, 6)

  private fun first(text: String): LabelDate = LabelDates.find(text, today).dates.first()

  private fun said(text: String): String? = LabelDates.answer(LabelDates.find(text, today), today)

  @Test
  fun numericDayFirstDates() {
    assertEquals(LabelDate(DateKind.BEST_BEFORE, 2027, 3, 12), first("BB 12/03/27"))
    assertEquals(LabelDate(DateKind.BEST_BEFORE, 2027, 3, 12), first("Best before: 12.03.2027"))
    assertEquals(LabelDate(DateKind.USE_BY, 2027, 3, 12), first("USE BY 12-03-27"))
    assertEquals(LabelDate(DateKind.BEST_BEFORE, 2027, 3, 12), first("Best Before 12 03 2027"))
    assertEquals("Best before 12 March 2027.", said("BB 12/03/27"))
  }

  @Test
  fun monthFirstOnlyWhenDayFirstIsImpossible() {
    assertEquals(LabelDate(DateKind.EXPIRY, 2027, 3, 25), first("EXP 03/25/2027"))
  }

  @Test
  fun isoAndYearMonthDates() {
    assertEquals(LabelDate(DateKind.EXPIRY, 2027, 3, 12), first("EXP 2027-03-12"))
    val ym = first("EXP 2027-03")
    assertEquals(LabelDate(DateKind.EXPIRY, 2027, 3, null, endOfMonth = true), ym)
    assertEquals("Expiry date the end of March 2027.", said("EXP 2027-03"))
  }

  @Test
  fun monthNames() {
    assertEquals(LabelDate(DateKind.BEST_BEFORE, 2027, 3, 12), first("Best before 12 March 2027"))
    assertEquals(LabelDate(DateKind.BEST_BEFORE, 2027, 3, 12), first("BEST BEFORE 12MAR27"))
    assertEquals(LabelDate(DateKind.BEST_BEFORE, 2027, 3, 12), first("BBE 12 MAR 2027"))
    assertEquals(LabelDate(DateKind.EXPIRY, 2027, 3, 12), first("Expires March 12, 2027"))
    assertEquals(LabelDate(DateKind.BEST_BEFORE, 2027, 1, 5), first("best before 5th Jan 2027"))
  }

  @Test
  fun dayAndMonthWithoutYearTakeTheNearestYearAndDontSayIt() {
    // 12 March: next March (126 days away) is nearer than last March (239 days ago).
    val d = first("use by 12 MAR")
    assertEquals(LabelDate(DateKind.USE_BY, 2027, 3, 12, yearGuessed = true), d)
    assertEquals("Use by 12 March.", said("use by 12 MAR"))
    // 1 November: last week, so it has passed.
    assertEquals("Use by 1 November. That date has already passed.", said("USE BY 01 NOV"))
    // "BB 12/03": day and month.
    assertEquals(LabelDate(DateKind.BEST_BEFORE, 2027, 3, 12, yearGuessed = true), first("BB 12/03"))
  }

  @Test
  fun bestBeforeEndIsAMonth() {
    val d = first("best before end: 03 2027")
    assertEquals(LabelDate(DateKind.BEST_BEFORE, 2027, 3, null, endOfMonth = true), d)
    assertEquals("Best before the end of March 2027.", said("best before end: 03 2027"))
    assertEquals(LabelDate(DateKind.BEST_BEFORE, 2027, 3, null, endOfMonth = true), first("BBE 03/27"))
    assertEquals(LabelDate(DateKind.BEST_BEFORE, 2027, 3, null, endOfMonth = true), first("Best Before End MAR 27"))
    assertEquals(LabelDate(DateKind.EXPIRY, 2027, 3, null, endOfMonth = true), first("EXP 03/27"))
    assertEquals(LabelDate(DateKind.EXPIRY, 2028, 6, null, endOfMonth = true), first("EXP JUN 2028"))
  }

  @Test
  fun dateOnTheNextLine() {
    assertEquals(LabelDate(DateKind.BEST_BEFORE, 2027, 3, 12), first("BEST BEFORE\n12/03/2027"))
  }

  @Test
  fun pastDatesAreSaidAsPassed() {
    assertEquals("Best before 1 June 2026. That date has already passed.", said("BB 01/06/26"))
    // A month-only date isn't passed until the month is over.
    assertEquals("Best before the end of November 2026.", said("BBE 11 2026"))
    assertEquals("Best before the end of October 2026. That date has already passed.", said("BBE 10 2026"))
    assertEquals("Use by 6 November 2026. That's today.", said("Use by 06/11/2026"))
  }

  @Test
  fun twoKindsOfDate() {
    assertEquals(
        "Display until 10 March 2027. Use by 12 March 2027.",
        said("DISPLAY UNTIL 10/03/27\nUSE BY 12/03/27"),
    )
  }

  @Test
  fun unlabelledFullDatesAreReported() {
    val f = LabelDates.find("L2345 12/03/2027 10:42", today)
    assertEquals(LabelDate(DateKind.UNLABELLED, 2027, 3, 12), f.dates.single())
    // A labelled date wins over an unlabelled one.
    assertEquals("Best before 1 April 2027.", said("Packed 01/11/2026\nBest before 01/04/2027"))
  }

  @Test
  fun seeElsewhereAndKeywordWithoutADate() {
    assertEquals(
        "The label says the date is on the top. Turn it so I can see the top, then ask again.",
        said("Best before: see top of pack"),
    )
    assertEquals("lid", LabelDates.find("For use by date see lid", today).elsewhere)
    val f = LabelDates.find("BEST BEFORE ##/##", today)
    assertEquals(DateKind.BEST_BEFORE, f.keywordWithoutDate)
    assertTrue(said("BEST BEFORE ##/##")!!.startsWith("I can see best before, but I can't make out the date"))
  }

  @Test
  fun noDatesAtAll() {
    assertNull(said("Ingredients: oats, sugar, salt. Store in a cool dry place."))
    // Nutrition numbers and weights aren't dates.
    assertTrue(LabelDates.find("Energy 1580kJ / 375kcal per 100g. 500 g. Fat 12.5", today).dates.isEmpty())
    // Words that contain the keywords aren't keywords.
    assertTrue(LabelDates.find("Explore the BBC website. Expert taste.", today).dates.isEmpty())
  }

  @Test
  fun invalidDatesAreIgnored() {
    assertTrue(LabelDates.find("BB 31/02/27", today).dates.isEmpty())
    assertTrue(LabelDates.find("EXP 13/2027", today).dates.isEmpty())
  }
}
