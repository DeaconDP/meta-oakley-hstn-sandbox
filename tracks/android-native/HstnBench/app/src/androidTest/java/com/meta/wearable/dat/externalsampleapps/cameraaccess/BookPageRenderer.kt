// BookPageRenderer - draws a printed-book page for the book reader tests
//
// Justified serif body text with indented paragraph starts, a running header, a page number at the
// foot, and words hyphenated across line ends, so the real ML Kit + layout pipeline sees what a
// camera pointed at a book would. One or two pages per image (a two-page spread).

package com.meta.wearable.dat.externalsampleapps.cameraaccess

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.net.Uri
import java.io.File
import java.io.FileOutputStream

object BookPageRenderer {

  /** A body line. [last] lines (end of paragraph) are left-aligned, others justified. */
  data class Line(val text: String, val indent: Boolean = false, val last: Boolean = false)

  data class Page(val header: String?, val lines: List<Line>, val pageNumber: String?)

  /** Builds lines from paragraphs written with explicit line breaks ('\n'). */
  fun paragraphs(vararg paragraphs: String): List<Line> =
      paragraphs.flatMap { p ->
        val rows = p.split('\n')
        rows.mapIndexed { i, row -> Line(row, indent = i == 0, last = i == rows.size - 1) }
      }

  fun render(width: Int, height: Int, pages: List<Page>, textSize: Float = 28f): Bitmap {
    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    canvas.drawColor(Color.WHITE)
    val body =
        Paint(Paint.ANTI_ALIAS_FLAG).apply {
          color = Color.BLACK
          typeface = Typeface.SERIF
          this.textSize = textSize
        }
    val small =
        Paint(body).apply {
          this.textSize = textSize * 0.8f
          letterSpacing = 0.08f
        }
    val pageWidth = width / pages.size
    val margin = pageWidth * 0.08f
    val lineHeight = textSize * 1.45f
    pages.forEachIndexed { index, page ->
      val left = index * pageWidth + margin
      val right = (index + 1) * pageWidth - margin
      page.header?.let {
        val w = small.measureText(it)
        canvas.drawText(it, (left + right - w) / 2f, height * 0.07f, small)
      }
      var y = height * 0.07f + lineHeight * 2.2f
      for (line in page.lines) {
        val x = if (line.indent) left + textSize * 1.5f else left
        drawLine(canvas, line.text, x, right, y, justify = !line.last, paint = body)
        y += lineHeight
      }
      page.pageNumber?.let {
        val w = body.measureText(it)
        canvas.drawText(it, (left + right - w) / 2f, height * 0.94f, body)
      }
    }
    return bitmap
  }

  private fun drawLine(canvas: Canvas, text: String, left: Float, right: Float, y: Float, justify: Boolean, paint: Paint) {
    val words = text.split(' ')
    if (!justify || words.size == 1) {
      canvas.drawText(text, left, y, paint)
      return
    }
    val wordsWidth = words.sumOf { paint.measureText(it).toDouble() }.toFloat()
    val gap = (right - left - wordsWidth) / (words.size - 1)
    var x = left
    for (word in words) {
      canvas.drawText(word, x, y, paint)
      x += paint.measureText(word) + gap
    }
  }

  fun savePng(bitmap: Bitmap, dir: File, name: String): Uri {
    val file = File(dir, name)
    FileOutputStream(file).use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    return Uri.fromFile(file)
  }

  // MARK: - Test content (Conan Doyle and Wells, public domain; quotes dropped to keep OCR exact)

  val houndPage =
      Page(
          header = "THE HOUND OF THE BASKERVILLES",
          lines =
              paragraphs(
                  "Mr. Sherlock Holmes, who was usually very late in\n" +
                      "the mornings, save upon those not infrequent oc-\n" +
                      "casions when he was up all night, was seated at the\n" +
                      "breakfast table. I stood upon the hearth-rug and\n" +
                      "picked up the stick which our visitor had left be-\n" +
                      "hind him the night before. It was a fine, thick piece\n" +
                      "of wood, known as a Penang lawyer.",
                  "Well, Watson, what do you make of it?",
                  "Holmes was sitting with his back to me, and I had\n" +
                      "given him no sign of my occupation. How did you\n" +
                      "know what I was doing? I believe you have eyes in\n" +
                      "the back of your head.",
              ),
          pageNumber = "3",
      )

  /** What the reader should say for [houndPage]: no header, no page number, hyphens rejoined. */
  const val HOUND_EXPECTED =
      "Mr. Sherlock Holmes, who was usually very late in the mornings, save upon those not " +
          "infrequent occasions when he was up all night, was seated at the breakfast table. I " +
          "stood upon the hearth-rug and picked up the stick which our visitor had left behind " +
          "him the night before. It was a fine, thick piece of wood, known as a Penang lawyer.\n\n" +
          "Well, Watson, what do you make of it?\n\n" +
          "Holmes was sitting with his back to me, and I had given him no sign of my occupation. " +
          "How did you know what I was doing? I believe you have eyes in the back of your head."

  val timeMachineSpread =
      listOf(
          Page(
              header = "THE TIME MACHINE",
              lines =
                  paragraphs(
                      "The Time Traveller was expounding a recondite\n" +
                          "matter to us. His grey eyes shone and twinkled,\n" +
                          "and his usually pale face was flushed.",
                      "You must follow me carefully. I shall have to\n" +
                          "controvert one or two ideas that are almost uni-\n" +
                          "versally accepted. The geometry they taught you\n" +
                          "at school is founded on a misconception. It is ex-",
                  ).let { lines -> lines.dropLast(1) + lines.last().copy(last = false) },
              pageNumber = "42",
          ),
          Page(
              header = "A STRANGE ARRIVAL",
              lines =
                  listOf(Line("traordinarily simple, and you will soon admit it.", last = true)) +
                      paragraphs(
                          "Is not that rather a large thing to expect us to\n" +
                              "begin upon, said Filby, an argumentative person\n" +
                              "with red hair.",
                      ),
              pageNumber = "43",
          ),
      )

  const val TIME_MACHINE_EXPECTED =
      "The Time Traveller was expounding a recondite matter to us. His grey eyes shone and " +
          "twinkled, and his usually pale face was flushed.\n\n" +
          "You must follow me carefully. I shall have to controvert one or two ideas that are " +
          "almost universally accepted. The geometry they taught you at school is founded on a " +
          "misconception. It is extraordinarily simple, and you will soon admit it.\n\n" +
          "Is not that rather a large thing to expect us to begin upon, said Filby, an " +
          "argumentative person with red hair."
}
