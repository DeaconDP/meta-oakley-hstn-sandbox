// Codes - what a decoded barcode is, and what to say about it
//
// ML Kit gives a raw value and a format. Product barcodes (EAN-13, EAN-8, UPC-A, UPC-E) can be
// looked up; their check digit is verified first so a misread never reaches Open Food Facts. QR
// codes are described, never opened: a web address is said as its domain ("It links to
// example.com"), Wi-Fi codes give the network name but not the password, other text is read (up to
// a sentence or two). Other 1D codes (shipping, shelf labels) are read as digits. Pure Kotlin,
// JVM-tested.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.labels

enum class CodeKind { PRODUCT, QR, OTHER }

/** A decoded code. [format] is a short name ("EAN-13", "QR"), for the screen. */
data class ScannedCode(val raw: String, val kind: CodeKind, val format: String) {
  /** The number to look up: digits, with UPC-A padded to 13. Null if it isn't a valid product code. */
  val productCode: String?
    get() = if (kind == CodeKind.PRODUCT) Codes.productCode(raw) else null
}

object Codes {

  /** GS1 check digit (EAN-8, UPC-A, EAN-13, GTIN-14): true if the last digit matches. */
  fun checkDigitOk(digits: String): Boolean {
    if (digits.length !in setOf(8, 12, 13, 14) || !digits.all { it.isDigit() }) return false
    val body = digits.dropLast(1)
    var sum = 0
    // Weights 3,1,3,1... from the rightmost digit of the body.
    body.reversed().forEachIndexed { i, c -> sum += (c - '0') * if (i % 2 == 0) 3 else 1 }
    return (10 - sum % 10) % 10 == digits.last() - '0'
  }

  /** The lookup form: UPC-A (12) becomes EAN-13 with a leading 0; UPC-E (8, starts 0/1) as is. */
  fun productCode(raw: String): String? {
    val d = raw.trim()
    if (!d.all { it.isDigit() }) return null
    return when (d.length) {
      13, 8 -> if (checkDigitOk(d)) d else if (d.length == 8 && upcEOk(d)) d else null
      12 -> if (checkDigitOk(d)) "0$d" else null
      else -> null
    }
  }

  /** UPC-E check: expand to UPC-A and check that. */
  private fun upcEOk(d: String): Boolean {
    if (d[0] != '0' && d[0] != '1') return false
    val m = d.substring(1, 7)
    val s = d[0].toString()
    val upcA =
        when (m[5]) {
          '0', '1', '2' -> s + m.substring(0, 2) + m[5] + "0000" + m.substring(2, 5)
          '3' -> s + m.substring(0, 3) + "00000" + m.substring(3, 5)
          '4' -> s + m.substring(0, 4) + "00000" + m[4]
          else -> s + m.substring(0, 5) + "0000" + m[5]
        } + d[7]
    return checkDigitOk(upcA)
  }

  /** "5012345678900" → "5 0 1 2 ...": digits said one by one. */
  fun spokenDigits(raw: String): String = raw.filter { it.isLetterOrDigit() }.toList().joinToString(" ")

  private val URL = Regex("^(?:https?://)?(?:www\\.)?([a-z0-9.-]+\\.[a-z]{2,})(?:[:/?#].*)?$", RegexOption.IGNORE_CASE)

  /** What to say about a QR code's content. Never opens anything. */
  fun describeQr(raw: String): String {
    val v = raw.trim()
    val lower = v.lowercase()
    return when {
      lower.startsWith("http://") || lower.startsWith("https://") || lower.startsWith("www.") ->
          URL.find(v)?.let { "This is a QR code. It links to ${it.groupValues[1].lowercase()}. I won't open links." }
              ?: "This is a QR code with a web link. I won't open links."
      lower.startsWith("wifi:") -> {
        val name = Regex("(?:^|;)S:((?:\\\\.|[^;])*)", RegexOption.IGNORE_CASE).find(v.substring(5))?.groupValues?.get(1)
        "This is a QR code for a Wi-Fi network" + (name?.let { " called ${it.replace("\\", "")}" } ?: "") + "."
      }
      lower.startsWith("mailto:") -> "This is a QR code with an email address: ${v.substring(7).substringBefore('?')}."
      lower.startsWith("tel:") -> "This is a QR code with a phone number: ${spokenDigits(v.substring(4))}."
      lower.startsWith("begin:vcard") -> "This is a QR code with contact details."
      v.isEmpty() -> "This is a QR code, but it's empty."
      else -> {
        val text = if (v.length > 200) v.take(200).substringBeforeLast(' ') + "…" else v
        "This is a QR code. It says: $text"
      }
    }
  }
}
