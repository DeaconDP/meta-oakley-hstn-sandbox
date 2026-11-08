// OpenFoodFactsTest - parsing recorded Open Food Facts replies, what is said, and the cached source
//
// Fixtures in app/src/test/resources/labels/ were recorded from world.openfoodfacts.org on
// 2026-11-06: Snickers (full reply), a dietary supplement under 5012345678900 (full reply), Nutella
// (the fields the app asks for), and a "no code or invalid code" reply. No live API in tests.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.labels

import java.io.File
import java.net.UnknownHostException
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OpenFoodFactsTest {

  private fun fixture(name: String): String =
      javaClass.classLoader!!.getResource("labels/$name")!!.readText()

  private fun found(name: String): OffProduct = (OpenFoodFacts.parse(fixture(name)) as LookupResult.Found).product

  @Test
  fun miniJsonReadsTheBasics() {
    val v = MiniJson.parse("""{"a":[1,2.5,-3e2],"b":{"c":"x\"yé\n"},"d":true,"e":null,"f":false}""") as Map<*, *>
    assertEquals(listOf(1.0, 2.5, -300.0), v["a"])
    assertEquals("x\"yé\n", (v["b"] as Map<*, *>)["c"])
    assertEquals(true, v["d"])
    assertNull(v["e"])
    assertEquals(false, v["f"])
    assertEquals(emptyList<Any>(), MiniJson.parse(" [ ] "))
  }

  @Test(expected = IllegalArgumentException::class)
  fun miniJsonRejectsBrokenInput() {
    MiniJson.parse("{\"a\": [1, 2}")
  }

  @Test
  fun fullSnickersReply() {
    val p = found("off_snickers_full.json")
    assertEquals("5000159461122", p.code)
    assertEquals("Snickers", p.name)
    assertEquals(listOf("Mars Wrigley Confectionery UK Limited", "Snickers"), p.brands)
    assertEquals(listOf("Mars Wrigley Confectionery UK Limited"), p.otherBrands)
    assertEquals("50 G", p.quantity)
    assertEquals(listOf("eggs", "milk", "peanuts", "soya"), p.allergens)
    assertEquals(listOf("nuts"), p.traces)
    assertTrue(p.ingredients!!.startsWith("Milk Chocolate"))
    assertTrue("en:chocolate-candies" in p.categoryTags)
    assertEquals("Snickers, by Mars Wrigley Confectionery UK Limited, 50 grams.", p.summary())
    assertFalse(MedicineCheck.looksLikeMedicine(p.name!!, p.categoryTags))
  }

  @Test
  fun fieldsOnlyNutellaReply() {
    val p = found("off_nutella_fields.json")
    assertEquals("Nutella", p.name)
    assertEquals(listOf("Ferrero"), p.otherBrands)
    // "400 g e": the ℮ (estimated) mark is dropped.
    assertEquals("Nutella, by Ferrero, 400 grams.", p.summary())
    assertEquals(listOf("milk", "nuts", "soya"), p.allergens)
    assertTrue(p.traces.isEmpty())
  }

  @Test
  fun supplementCategoryCountsAsMedicine() {
    val p = found("off_supplement_full.json")
    assertEquals(listOf("en:dietary-supplements"), p.categoryTags)
    assertTrue(MedicineCheck.looksLikeMedicine(p.name.orEmpty(), p.categoryTags))
  }

  @Test
  fun notFound() {
    assertEquals(LookupResult.NotFound, OpenFoodFacts.parse(fixture("off_not_found.json")))
    assertEquals(LookupResult.NotFound, OpenFoodFacts.parse("""{"code":"123","status":0,"status_verbose":"product not found"}"""))
  }

  @Test
  fun productWithNoNameStillSaysSomething() {
    val r = OpenFoodFacts.parse("""{"code":"1","status":1,"product":{"brands":"Acme","quantity":"1 l"}}""")
    assertEquals("A product with no name recorded, by Acme, 1 litres.", (r as LookupResult.Found).product.summary())
  }

  @Test
  fun quantitiesAndTags() {
    assertEquals("330 millilitres", OpenFoodFacts.spokenQuantity("330ml"))
    assertEquals("6 x 330 millilitres", OpenFoodFacts.spokenQuantity("6 x 330 ml"))
    assertEquals("1.5 kilograms", OpenFoodFacts.spokenQuantity("1.5kg ℮"))
    assertEquals("sesame", OpenFoodFacts.tagName("en:sesame-seeds"))
    assertEquals("fruits a coque", OpenFoodFacts.tagName("fr:fruits-a-coque"))
  }

  @Test
  fun onlyTheBarcodeGoesInTheRequest() {
    val url = OpenFoodFacts.url("5000159461122")
    assertTrue(url.startsWith("https://world.openfoodfacts.org/api/v2/product/5000159461122.json?fields="))
  }

  @Test
  fun sourceCachesFoundProductsAndReportsOffline() = runBlocking {
    val dir = Files.createTempDirectory("off").toFile()
    var calls = 0
    val body = fixture("off_snickers_full.json")
    val online = OpenFoodFactsSource(dir) { calls++; 200 to body }
    val first = online.lookup("5000159461122") as LookupResult.Found
    assertFalse(first.fromCache)
    assertTrue(File(dir, "5000159461122.json").isFile)
    // Offline now, but the cache answers.
    val offline = OpenFoodFactsSource(dir) { throw UnknownHostException("no network") }
    val cached = offline.lookup("5000159461122") as LookupResult.Found
    assertTrue(cached.fromCache)
    assertEquals("Snickers", cached.product.name)
    assertEquals(LookupResult.Offline, offline.lookup("3017620422003"))
    assertEquals(1, calls)
    // Open Food Facts answers an unknown product with 404 and status 0.
    val unknown = OpenFoodFactsSource(dir) { 404 to fixture("off_not_found.json") }
    assertEquals(LookupResult.NotFound, unknown.lookup("4000000000006"))
    assertFalse(File(dir, "4000000000006.json").exists())
    val broken = OpenFoodFactsSource(dir) { 503 to "" }
    assertTrue(broken.lookup("4000000000006") is LookupResult.Failed)
    dir.deleteRecursively()
    Unit
  }
}
