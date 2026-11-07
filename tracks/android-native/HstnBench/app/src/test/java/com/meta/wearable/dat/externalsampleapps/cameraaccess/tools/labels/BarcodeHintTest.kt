// BarcodeHintTest - barcode-like patches for the search ticks, and what decoded codes mean
//
// Synthetic rows: an EAN-13 bar pattern drawn at a given place and size, lines of "text" (random
// letter-like blobs that change from row to row), and flat paper.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.labels

import kotlin.random.Random
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BarcodeHintTest {

  private val width = 480
  private val rows = 48

  /** EAN-13 modules for 5012345678900 (95 modules, true = bar). */
  private fun ean13(code: String): BooleanArray {
    val l = listOf("0001101", "0011001", "0010011", "0111101", "0100011", "0110001", "0101111", "0111011", "0110111", "0001011")
    val g = listOf("0100111", "0110011", "0011011", "0100001", "0011101", "0111001", "0000101", "0010001", "0001001", "0010111")
    val r = listOf("1110010", "1100110", "1101100", "1000010", "1011100", "1001110", "1010000", "1000100", "1001000", "1110100")
    val parity = listOf("LLLLLL", "LLGLGG", "LLGGLG", "LLGGGL", "LGLLGG", "LGGLLG", "LGGGLL", "LGLGLG", "LGLGGL", "LGGLGL")
    val d = code.map { it - '0' }
    val sb = StringBuilder("101")
    for (i in 1..6) sb.append(if (parity[d[0]][i - 1] == 'L') l[d[i]] else g[d[i]])
    sb.append("01010")
    for (i in 7..12) sb.append(r[d[i]])
    sb.append("101")
    return BooleanArray(sb.length) { sb[it] == '1' }
  }

  private fun frame(barLeft: Int = -1, barWidth: Int = 0, barTop: Int = 0, barRows: Int = 0, textRows: IntRange? = null): IntArray {
    val luma = IntArray(width * rows) { 230 }
    if (barWidth > 0) {
      val modules = ean13("5012345678900")
      for (r in barTop until barTop + barRows) for (x in barLeft until barLeft + barWidth) {
        val m = (x - barLeft) * modules.size / barWidth
        if (modules[m]) luma[r * width + x] = 25
      }
    }
    if (textRows != null) {
      val rnd = Random(7)
      for (r in textRows) {
        var x = 20
        while (x < width - 20) {
          val w = rnd.nextInt(2, 6)
          if (rnd.nextFloat() < 0.5f) for (k in x until minOf(width, x + w)) luma[r * width + k] = 30
          x += w + rnd.nextInt(2, 6)
        }
      }
    }
    return luma
  }

  @Test
  fun findsABarcodeAndItsPlace() {
    val r = BarcodeHint.find(frame(barLeft = 120, barWidth = 240, barTop = 18, barRows = 10), width, rows)
    assertNotNull(r)
    r!!
    assertEquals(0.25f, r.left, 0.03f)
    assertEquals(0.75f, r.right, 0.03f)
    assertTrue(r.top in 0.3f..0.45f)
    assertTrue("centred and half the width: ${r.closeness}", r.closeness > 0.85f)
  }

  @Test
  fun smallerOrOffCentreIsLessClose() {
    val small = BarcodeHint.find(frame(barLeft = 190, barWidth = 100, barTop = 20, barRows = 6), width, rows)!!
    val corner = BarcodeHint.find(frame(barLeft = 10, barWidth = 200, barTop = 2, barRows = 6), width, rows)!!
    val big = BarcodeHint.find(frame(barLeft = 120, barWidth = 240, barTop = 18, barRows = 10), width, rows)!!
    assertTrue(small.closeness < big.closeness)
    assertTrue(corner.closeness < big.closeness)
  }

  @Test
  fun textAndPaperAreNotBarcodes() {
    assertNull(BarcodeHint.find(frame(), width, rows))
    assertNull(BarcodeHint.find(frame(textRows = 4..40), width, rows))
  }

  @Test
  fun barcodeNextToText() {
    val luma = frame(barLeft = 140, barWidth = 200, barTop = 30, barRows = 8)
    val text = frame(textRows = 2..20)
    for (i in 0 until width * 21) luma[i] = text[i]
    val r = BarcodeHint.find(luma, width, rows)
    assertNotNull(r)
    assertTrue(r!!.top >= 0.55f)
  }

  @Test
  fun checkDigitsAndProductCodes() {
    assertTrue(Codes.checkDigitOk("5012345678900"))
    assertTrue(Codes.checkDigitOk("3017620422003"))
    assertTrue(Codes.checkDigitOk("96385074")) // EAN-8
    assertFalse(Codes.checkDigitOk("5012345678901"))
    assertEquals("5000159461122", Codes.productCode("5000159461122"))
    assertEquals("0036000291452", Codes.productCode("036000291452")) // UPC-A padded
    assertEquals("01234565", Codes.productCode("01234565")) // UPC-E
    assertNull(Codes.productCode("5012345678901"))
    assertNull(Codes.productCode("ABC"))
    assertEquals(null, ScannedCode("5012345678901", CodeKind.PRODUCT, "EAN-13").productCode)
    assertEquals(null, ScannedCode("5012345678900", CodeKind.OTHER, "barcode").productCode)
  }

  @Test
  fun qrCodesAreDescribedNotOpened() {
    assertEquals(
        "This is a QR code. It links to example.com. I won't open links.",
        Codes.describeQr("https://www.example.com/promo?id=42"),
    )
    assertEquals("This is a QR code. It links to shop.example.co.uk. I won't open links.", Codes.describeQr("http://shop.example.co.uk"))
    assertEquals("This is a QR code for a Wi-Fi network called Cafe Guest.", Codes.describeQr("WIFI:T:WPA;S:Cafe Guest;P:secret123;;"))
    assertFalse(Codes.describeQr("WIFI:T:WPA;S:Cafe Guest;P:secret123;;").contains("secret"))
    assertEquals("This is a QR code. It says: Table 12", Codes.describeQr("Table 12"))
    assertEquals("This is a QR code with a phone number: 0 1 2 3 4.", Codes.describeQr("tel:01234"))
    assertTrue(Codes.describeQr("x".repeat(10) + " " + "word ".repeat(80)).endsWith("…"))
  }
}
