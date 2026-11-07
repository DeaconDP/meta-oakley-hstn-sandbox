// MedicineExpiryTest - a medicine's expiry date: said only when read clearly, always with a reminder

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.labels

import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MedicineExpiryTest {

  private val today = LocalDate.of(2026, 11, 7)
  private fun answer(text: String) = LabelDates.answer(LabelDates.find(text, today), today)

  @Test
  fun aClearDateIsSaidWithTheReminder() {
    val said = MedicineCheck.expiry(answer("EXP 06/2028"), listOf(0.95f))!!
    assertTrue(said, said.startsWith("Expiry date"))
    assertTrue(said, said.contains("2028"))
    assertTrue(said, said.endsWith(MedicineCheck.EXPIRY_CHECK))
  }

  @Test
  fun anUnsureLineMeansNoDateAtAll() {
    val said = MedicineCheck.expiry(answer("EXP 06/2028"), listOf(0.95f, 0.6f))
    assertEquals(MedicineCheck.EXPIRY_UNSURE, said)
    assertFalse(said!!.contains("2028"))
  }

  @Test
  fun noConfidenceFromTheEngineCountsAsUnsure() {
    assertEquals(MedicineCheck.EXPIRY_UNSURE, MedicineCheck.expiry(answer("EXP 06/2028"), listOf(null)))
  }

  @Test
  fun noDateFoundIsLeftToTheCaller() {
    assertNull(MedicineCheck.expiry(null, emptyList()))
  }

  @Test
  fun aPassedDateStillGetsTheReminder() {
    val said = MedicineCheck.expiry(answer("EXP 01/2025"), listOf(0.9f))!!
    assertTrue(said, said.contains("already passed"))
    assertTrue(said, said.endsWith(MedicineCheck.EXPIRY_CHECK))
  }
}
