// LabelRenderer - draws a product label, with a real EAN-13 barcode, for the label reader tests
//
// A white label with the product name in big print, a few lines of smaller text (ingredients, a
// best-before date, or a medicine's directions) and optionally an EAN-13 barcode drawn from its
// digits (the standard L/G/R encodings, guard bars and parity from the first digit), so ML Kit has
// a genuine barcode to decode. Sizes scale with the image, so the same label can be the stream
// (480x864 video) and the in-stream photo (960x1440).

package com.meta.wearable.dat.externalsampleapps.cameraaccess

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface

object LabelRenderer {

  data class Label(val title: String, val lines: List<String>, val barcode: String? = null)

  val cereal =
      Label(
          title = "OAT CRUNCH",
          lines =
              listOf(
                  "Crunchy oat clusters",
                  "Ingredients: Wholegrain oats,",
                  "sugar, almonds, honey, salt.",
                  "Best before: 12/03/27",
              ),
          barcode = "4006381333931",
      )

  val paracetamol =
      Label(
          title = "PARACETAMOL",
          lines =
              listOf(
                  "500 mg Tablets",
                  "Dosage: adults take 2 tablets",
                  "every 4 hours. Do not exceed",
                  "8 tablets in 24 hours.",
                  "EXP 2028-06",
              ),
      )

  fun render(label: Label, width: Int, height: Int): Bitmap {
    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    canvas.drawColor(Color.WHITE)
    val unit = width / 480f
    val title =
        Paint(Paint.ANTI_ALIAS_FLAG).apply {
          color = Color.BLACK
          typeface = Typeface.create(Typeface.SANS_SERIF, Typeface.BOLD)
          textSize = 52f * unit
        }
    val body =
        Paint(Paint.ANTI_ALIAS_FLAG).apply {
          color = Color.BLACK
          typeface = Typeface.SANS_SERIF
          textSize = 26f * unit
        }
    val left = 40f * unit
    var y = height * 0.1f
    canvas.drawText(label.title, left, y, title)
    y += 60f * unit
    for (line in label.lines) {
      canvas.drawText(line, left, y, body)
      y += 38f * unit
    }
    label.barcode?.let { drawEan13(canvas, it, left = 60f * unit, top = y + 30f * unit, width = 360f * unit, height = 150f * unit) }
    return bitmap
  }

  private val L = listOf("0001101", "0011001", "0010011", "0111101", "0100011", "0110001", "0101111", "0111011", "0110111", "0001011")
  private val G = listOf("0100111", "0110011", "0011011", "0100001", "0011101", "0111001", "0000101", "0010001", "0001001", "0010111")
  private val R = listOf("1110010", "1100110", "1101100", "1000010", "1011100", "1001110", "1010000", "1000100", "1001000", "1110100")
  private val PARITY = listOf("LLLLLL", "LLGLGG", "LLGGLG", "LLGGGL", "LGLLGG", "LGGLLG", "LGGGLL", "LGLGLG", "LGLGGL", "LGGLGL")

  /** The 95 modules of an EAN-13 (1 = bar). */
  fun ean13Modules(code: String): String {
    require(code.length == 13 && code.all { it.isDigit() })
    val d = code.map { it - '0' }
    val sb = StringBuilder("101")
    for (i in 1..6) sb.append(if (PARITY[d[0]][i - 1] == 'L') L[d[i]] else G[d[i]])
    sb.append("01010")
    for (i in 7..12) sb.append(R[d[i]])
    sb.append("101")
    return sb.toString()
  }

  private fun drawEan13(canvas: Canvas, code: String, left: Float, top: Float, width: Float, height: Float) {
    val modules = ean13Modules(code)
    val m = width / modules.length
    val bar = Paint().apply { color = Color.BLACK }
    modules.forEachIndexed { i, c -> if (c == '1') canvas.drawRect(left + i * m, top, left + (i + 1) * m, top + height, bar) }
    val digits =
        Paint(Paint.ANTI_ALIAS_FLAG).apply {
          color = Color.BLACK
          typeface = Typeface.MONOSPACE
          textSize = m * 9f
        }
    canvas.drawText(code, left + m * 6, top + height + m * 9f, digits)
  }
}
