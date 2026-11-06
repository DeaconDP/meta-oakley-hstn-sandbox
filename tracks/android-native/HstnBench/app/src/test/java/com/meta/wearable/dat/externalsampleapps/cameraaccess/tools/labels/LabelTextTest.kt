// LabelTextTest - sections, the product name, allergen answers, and medicine detection
//
// Allergen answers must never say "no" just because the word wasn't found.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.labels

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LabelTextTest {

  private val cereal =
      listOf(
          LabelLine("OAT CRUNCH", 60f),
          LabelLine("Crunchy oat clusters", 30f),
          LabelLine("Ingredients: Wholegrain oats (55%), sugar,", 18f),
          LabelLine("almonds (6%), honey, salt.", 18f),
          LabelLine("Allergy advice: for allergens, see", 18f),
          LabelLine("ingredients in bold. May contain milk.", 18f),
          LabelLine("Nutrition information per 100g", 18f),
          LabelLine("Energy 1580kJ", 18f),
          LabelLine("Best before: 12/03/2027", 18f),
      )

  private fun label(lines: List<LabelLine>) = lines.joinToString("\n") { it.text }

  @Test
  fun ingredientsSectionEndsAtTheNextHeading() {
    assertEquals(
        "Wholegrain oats (55%), sugar, almonds (6%), honey, salt.",
        LabelText.section(cereal, LabelSection.INGREDIENTS),
    )
    assertEquals(
        "for allergens, see ingredients in bold. May contain milk.",
        LabelText.section(cereal, LabelSection.ALLERGENS),
    )
    assertNull(LabelText.section(cereal, LabelSection.COOKING))
  }

  @Test
  fun cookingSectionKeepsItsSubheadings() {
    val pie =
        listOf(
            LabelLine("Cooking instructions", 20f),
            LabelLine("Oven: 200C, Fan 180C, Gas 6.", 16f),
            LabelLine("Remove film. Cook for 25 minutes.", 16f),
            LabelLine("Microwave: 800W 4 mins, stand 1 min.", 16f),
            LabelLine("Storage: keep refrigerated.", 16f),
        )
    assertEquals(
        "Cooking instructions Oven: 200C, Fan 180C, Gas 6. Remove film. Cook for 25 minutes. Microwave: 800W 4 mins, stand 1 min.",
        LabelText.section(pie, LabelSection.COOKING),
    )
  }

  @Test
  fun nameIsTheBiggestPrint() {
    assertEquals("OAT CRUNCH", LabelText.nameGuess(cereal))
    assertEquals("Paracetamol 500 mg Tablets", LabelText.nameGuess(listOf(LabelLine("Paracetamol 500 mg Tablets", 50f), LabelLine("16 tablets", 20f))))
    assertNull(LabelText.nameGuess(listOf(LabelLine("12", 40f))))
  }

  @Test
  fun allergenFoundInIngredients() {
    val a = LabelText.allergenAnswer("nuts", label(cereal), null)
    assertEquals("Yes. The label mentions almonds.", a)
  }

  @Test
  fun mayContainIsTraces() {
    val a = LabelText.allergenAnswer("milk", label(cereal), null)
    assertEquals("It may contain milk. The label says: May contain milk.", a)
  }

  @Test
  fun notFoundIsNeverNo() {
    val a = LabelText.allergenAnswer("sesame", label(cereal), null)
    assertTrue(a, a.startsWith("I couldn't find sesame on the part of the label I read."))
    assertTrue(a.contains("That doesn't mean it's free from sesame"))
    assertFalse(a.startsWith("No"))
    val none = LabelText.allergenAnswer("eggs", null, null)
    assertTrue(none.startsWith("I couldn't find eggs anywhere yet."))
  }

  @Test
  fun freeFromIsQuoted() {
    val a = LabelText.allergenAnswer("gluten", "Gluten free oat bars. Ingredients: rice, sugar.", null)
    assertEquals("The label says: Gluten free oat bars.", a)
    val b = LabelText.allergenAnswer("nuts", "Free from nuts and peanuts.", null)
    assertTrue(b, b.startsWith("Yes") || b.startsWith("The label says"))
  }

  @Test
  fun lookAlikesDontCount() {
    val a = LabelText.allergenAnswer("milk", "Ingredients: sugar, cocoa butter, cocoa mass, coconut milk powder.", null)
    assertTrue(a, a.startsWith("I couldn't find milk"))
    val b = LabelText.allergenAnswer("nuts", "Ingredients: pumpkin, nutmeg, coconut.", null)
    assertTrue(b, b.startsWith("I couldn't find nuts"))
    // Peanuts are reported to someone asking about nuts.
    assertEquals("Yes. The label mentions peanuts.", LabelText.allergenAnswer("nuts", "Ingredients: peanuts, salt.", null))
  }

  @Test
  fun productDataAnswersToo() {
    val snickers =
        OffProduct("1", "Snickers", listOf("Mars"), "50 g", listOf("en:milk", "en:peanuts"), listOf("en:nuts"), null, emptyList())
    assertEquals("Yes. Open Food Facts lists milk as an allergen in this product.", LabelText.allergenAnswer("dairy", null, snickers))
    assertEquals("Yes. Open Food Facts lists nuts as an allergen in this product.", LabelText.allergenAnswer("nuts", null, snickers))
    val plain = snickers.copy(allergenTags = emptyList(), traceTags = listOf("en:sesame-seeds"))
    assertEquals("It may contain sesame. Open Food Facts lists it as a possible trace.", LabelText.allergenAnswer("sesame", null, plain))
    val nothing = LabelText.allergenAnswer("fish", "Ingredients: oats.", plain)
    assertTrue(nothing.startsWith("I couldn't find fish on the label or in the product data."))
  }

  @Test
  fun allergenSummary() {
    val snickers =
        OffProduct("1", "Snickers", listOf("Mars"), "50 g", listOf("en:milk", "en:peanuts"), listOf("en:nuts"), null, emptyList())
    assertEquals(
        "Allergy advice on the label: for allergens, see ingredients in bold. May contain milk. Open Food Facts lists milk and peanuts. It may contain traces of nuts.",
        LabelText.allergenSummary(cereal, snickers),
    )
    assertNull(LabelText.allergenSummary(listOf(LabelLine("Oats")), null))
  }

  @Test
  fun medicineDetection() {
    assertTrue(MedicineCheck.looksLikeMedicine("Paracetamol 500 mg Tablets. Adults: take 2 tablets every 4 hours."))
    assertTrue(MedicineCheck.looksLikeMedicine("Hay fever relief. 30 capsules"))
    assertTrue(MedicineCheck.looksLikeMedicine("Read the patient information leaflet"))
    assertTrue(MedicineCheck.looksLikeMedicine("Pharmacy medicine"))
    assertTrue(MedicineCheck.looksLikeMedicine("Dosage: see leaflet"))
    // Two weak signs.
    assertTrue(MedicineCheck.looksLikeMedicine("Vitamin D 25 mcg. Take one daily with food."))
    // Food: at most one weak sign.
    assertFalse(MedicineCheck.looksLikeMedicine(label(cereal) + "\nSodium 400mg. % Daily Value 17%"))
    assertFalse(MedicineCheck.looksLikeMedicine("Take care, contents hot. Salt 0.5g. Sodium 200mg"))
    assertFalse(MedicineCheck.looksLikeMedicine("Heinz Baked Beans in tomato sauce"))
    assertTrue(MedicineCheck.looksLikeMedicine("Zinc", listOf("en:dietary-supplements")))
    assertTrue(MedicineCheck.looksLikeMedicine("", listOf("en:medicines")))
  }

  @Test
  fun medicineNamesLoseTheirStrength() {
    assertEquals("Paracetamol Tablets", MedicineCheck.nameOnly("Paracetamol 500 mg Tablets"))
    assertEquals("Ibuprofen", MedicineCheck.nameOnly("Ibuprofen 200mg x 16"))
    assertEquals("Cough Syrup", MedicineCheck.nameOnly("Cough Syrup 5 ml"))
    assertEquals("a medicine", MedicineCheck.nameOnly("500 mg"))
  }
}
