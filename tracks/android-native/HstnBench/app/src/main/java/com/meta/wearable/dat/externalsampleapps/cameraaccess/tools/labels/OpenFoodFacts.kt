// OpenFoodFacts - the product lookup, its reply, and what is said about the product
//
// The label reader's only network call, made only when the user says "look it up" after a barcode
// decoded. Only the barcode number is sent (GET /api/v2/product/<code>.json, no key, a descriptive
// User-Agent as Open Food Facts asks); never an image or any label text. Found products are cached
// on the phone (one JSON file per barcode), so asking again works offline.
//
// [OpenFoodFacts.parse] turns the reply into an [OffProduct] (name, brands, quantity, allergen and
// trace tags, ingredients, categories). [ProductSource] is the seam tests replace with a fake; the
// ViewModel uses [LabelsLookup.source]. Pure Kotlin (java.net and java.io only, no Android imports),
// parsing JVM-tested against recorded replies in app/src/test/resources/labels/.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.labels

import java.io.File
import java.io.IOException
import java.net.ConnectException
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL
import java.net.UnknownHostException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** A product as Open Food Facts describes it. Lists hold tags such as "en:milk". */
data class OffProduct(
    val code: String,
    val name: String?,
    val brands: List<String>,
    val quantity: String?,
    val allergenTags: List<String>,
    val traceTags: List<String>,
    val ingredients: String?,
    val categoryTags: List<String>,
) {
  /** Brands without the product's own name ("Nutella, Ferrero" for Nutella gives "Ferrero"). */
  val otherBrands: List<String>
    get() = brands.filter { b -> name == null || !b.equals(name, ignoreCase = true) }

  val allergens: List<String>
    get() = allergenTags.map(OpenFoodFacts::tagName).distinct()

  val traces: List<String>
    get() = traceTags.map(OpenFoodFacts::tagName).distinct()

  /** "Snickers, by Mars Wrigley Confectionery UK Limited, 50 grams." */
  fun summary(): String {
    val parts = mutableListOf<String>()
    parts += name ?: "A product with no name recorded"
    otherBrands.firstOrNull()?.let { parts += "by $it" }
    quantity?.let { OpenFoodFacts.spokenQuantity(it) }?.takeIf { it.isNotBlank() }?.let { parts += it }
    return parts.joinToString(", ") + "."
  }
}

sealed interface LookupResult {
  data class Found(val product: OffProduct, val fromCache: Boolean = false) : LookupResult
  /** Open Food Facts doesn't know this barcode. */
  data object NotFound : LookupResult
  /** No network. */
  data object Offline : LookupResult
  data class Failed(val reason: String) : LookupResult
}

/** Where products come from. Tests inject a fake through [LabelsLookup.source]. */
fun interface ProductSource {
  suspend fun lookup(code: String): LookupResult
}

/** The product source the label reader uses. Null means the real one (set up by the ViewModel). */
object LabelsLookup {
  @Volatile var source: ProductSource? = null
}

object OpenFoodFacts {

  const val USER_AGENT =
      "HstnBench-LabelReader/0.1 (Android; accessibility app for blind users; barcode lookups only)"

  /** Only the fields the label reader speaks, to keep the reply small. */
  private const val FIELDS =
      "code,product_name,product_name_en,brands,quantity,allergens_tags,traces_tags," +
          "ingredients_text,ingredients_text_en,categories_tags"

  fun url(code: String): String =
      "https://world.openfoodfacts.org/api/v2/product/$code.json?fields=$FIELDS"

  /** A reply body to Found or NotFound. Throws IllegalArgumentException if it isn't JSON. */
  fun parse(json: String, requestedCode: String? = null): LookupResult {
    val root = MiniJson.parse(json) as? Map<*, *> ?: throw IllegalArgumentException("Not an object")
    val status = (root["status"] as? Double)?.toInt() ?: 0
    val product = root["product"] as? Map<*, *>
    if (status != 1 || product == null) return LookupResult.NotFound
    fun text(key: String) = (product[key] as? String)?.trim()?.takeIf { it.isNotEmpty() }
    fun tags(key: String) = (product[key] as? List<*>)?.filterIsInstance<String>().orEmpty()
    val brands =
        text("brands")
            ?.split(',')
            ?.map { it.trim() }
            ?.filter { it.isNotEmpty() }
            ?.distinctBy { it.lowercase() }
            .orEmpty()
    return LookupResult.Found(
        OffProduct(
            code = (root["code"] as? String) ?: requestedCode ?: "",
            name = text("product_name_en") ?: text("product_name"),
            brands = brands,
            quantity = text("quantity"),
            allergenTags = tags("allergens_tags"),
            traceTags = tags("traces_tags"),
            ingredients = text("ingredients_text_en") ?: text("ingredients_text"),
            categoryTags = tags("categories_tags"),
        ),
    )
  }

  private val TAG_NAMES =
      mapOf(
          "milk" to "milk", "nuts" to "nuts", "peanuts" to "peanuts", "soybeans" to "soya",
          "gluten" to "gluten", "eggs" to "eggs", "fish" to "fish", "crustaceans" to "crustaceans",
          "molluscs" to "molluscs", "sesame-seeds" to "sesame", "mustard" to "mustard",
          "celery" to "celery", "lupin" to "lupin", "sulphur-dioxide-and-sulphites" to "sulphites",
      )

  /** "en:soybeans" → "soya", "fr:fruits-a-coque" → "fruits a coque". */
  fun tagName(tag: String): String {
    val bare = tag.substringAfter(':')
    return TAG_NAMES[bare.lowercase()] ?: bare.replace('-', ' ').lowercase()
  }

  private val UNITS =
      mapOf(
          "g" to "grams", "gr" to "grams", "kg" to "kilograms", "mg" to "milligrams",
          "ml" to "millilitres", "cl" to "centilitres", "l" to "litres", "oz" to "ounces",
          "lb" to "pounds", "fl oz" to "fluid ounces",
      )

  /** "400 g e" → "400 grams", "50 G" → "50 grams", "6 x 330ml" → "6 x 330 millilitres". */
  fun spokenQuantity(raw: String): String {
    var q = raw.trim().replace('℮', ' ').replace(Regex("\\s+e$"), "").trim()
    q = q.replace(Regex("(\\d)\\s*(fl oz|kg|mg|ml|cl|gr|oz|lb|g|l)\\b", RegexOption.IGNORE_CASE)) { m ->
      "${m.groupValues[1]} ${UNITS[m.groupValues[2].lowercase()] ?: m.groupValues[2]}"
    }
    return q.replace(Regex("\\s+"), " ").trim()
  }
}

/**
 * The real lookup: the on-phone cache first, then Open Food Facts over HTTPS. Network work runs on
 * Dispatchers.IO. [cacheDir] holds one <code>.json per product found.
 */
class OpenFoodFactsSource(
    private val cacheDir: File,
    private val fetch: (String) -> Pair<Int, String> = ::httpGet,
) : ProductSource {

  override suspend fun lookup(code: String): LookupResult =
      withContext(Dispatchers.IO) {
        require(code.all { it.isDigit() }) { "Barcode must be digits" }
        val cached = File(cacheDir, "$code.json")
        if (cached.isFile) {
          runCatching { OpenFoodFacts.parse(cached.readText(), code) }
              .getOrNull()
              ?.let { if (it is LookupResult.Found) return@withContext it.copy(fromCache = true) }
        }
        try {
          val (status, body) = fetch(OpenFoodFacts.url(code))
          // A product Open Food Facts doesn't know comes back as 404 with status 0.
          if (status != 200 && status != 404) return@withContext LookupResult.Failed("HTTP $status")
          val result = OpenFoodFacts.parse(body, code)
          if (result is LookupResult.Found) {
            runCatching {
              cacheDir.mkdirs()
              cached.writeText(body)
            }
          }
          result
        } catch (e: UnknownHostException) {
          LookupResult.Offline
        } catch (e: ConnectException) {
          LookupResult.Offline
        } catch (e: SocketTimeoutException) {
          LookupResult.Offline
        } catch (e: IOException) {
          LookupResult.Failed(e.message ?: "network error")
        } catch (e: IllegalArgumentException) {
          LookupResult.Failed("unreadable reply")
        }
      }

  companion object {
    fun httpGet(url: String): Pair<Int, String> {
      val conn = URL(url).openConnection() as HttpURLConnection
      try {
        conn.connectTimeout = 8_000
        conn.readTimeout = 10_000
        conn.setRequestProperty("User-Agent", OpenFoodFacts.USER_AGENT)
        conn.setRequestProperty("Accept", "application/json")
        val status = conn.responseCode
        val stream = if (status >= 400) conn.errorStream else conn.inputStream
        val body = stream?.bufferedReader()?.use { it.readText() } ?: ""
        return status to body
      } finally {
        conn.disconnect()
      }
    }
  }
}
