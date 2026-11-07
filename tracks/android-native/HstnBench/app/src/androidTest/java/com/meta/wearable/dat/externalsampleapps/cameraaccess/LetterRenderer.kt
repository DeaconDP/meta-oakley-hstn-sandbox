// LetterRenderer - draws a printed letter for the mail reader tests
//
// A utility bill laid out like a real one: a bold letterhead with a small address and phone
// number on the right, the customer's address in the window position, the account number and date
// right-aligned beside it, a heading, "Dear ...", a paragraph, a table of charges with labels on
// the left and amounts right-aligned, the due date, and a signature. Sans-serif, like most bills.
// Options make the amount unreadable on purpose: [smudgeDigit] pixelates one digit of the amount
// due (a smudge or fold), [secondTotal] prints a second, different amount to pay.

package com.meta.wearable.dat.externalsampleapps.cameraaccess

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.Typeface

object LetterRenderer {

  const val AMOUNT = "£84.17"

  /** What "read it all" must say, in order (sentences of the letter). */
  val EXPECTED_SENTENCES =
      listOf(
          "Northgate Energy",
          "Mrs Jane Patel, 14 Elm Road, Leeds, LS6 2AB.",
          "Your electricity bill",
          "Dear Mrs Patel,",
          "Here is your bill for October.",
          "Standing charge £12.30.",
          "Amount due £84.17.",
          "Please pay the amount due by 24 November 2026.",
          "Yours sincerely,",
      )

  fun utilityBill(smudgeDigit: Int? = null, secondTotal: String? = null, width: Int = 960, height: Int = 1440): Bitmap {
    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    val c = Canvas(bitmap)
    c.drawColor(Color.WHITE)
    fun paint(size: Float, bold: Boolean = false) =
        Paint(Paint.ANTI_ALIAS_FLAG).apply {
          color = Color.BLACK
          typeface = Typeface.create(Typeface.SANS_SERIF, if (bold) Typeface.BOLD else Typeface.NORMAL)
          textSize = size
        }
    val body = paint(28f)
    val small = paint(22f)
    val left = 70f
    val right = width - 70f
    fun rightAligned(text: String, y: Float, p: Paint) = c.drawText(text, right - p.measureText(text), y, p)

    // Letterhead.
    c.drawText("Northgate Energy", left, 120f, paint(56f, bold = true))
    rightAligned("PO Box 512, Leeds LS1 4AB", 90f, small)
    rightAligned("Phone 0800 123 4567", 120f, small)

    // Window address, with the account number and date on the right.
    var y = 300f
    for (line in listOf("Mrs Jane Patel", "14 Elm Road", "Leeds", "LS6 2AB")) {
      c.drawText(line, left, y, body)
      y += 38f
    }
    rightAligned("Account number: 8842 1937 55", 300f, small)
    rightAligned("3 November 2026", 338f, small)

    c.drawText("Your electricity bill", left, 540f, paint(38f, bold = true))
    c.drawText("Dear Mrs Patel,", left, 610f, body)
    y = 670f
    for (line in listOf(
        "Here is your bill for October. Your Direct Debit is",
        "not set up, so please pay by bank transfer or by",
        "phone using the account number above.",
    )) {
      c.drawText(line, left, y, body)
      y += 38f
    }

    // Table of charges.
    y = 830f
    val rows = mutableListOf("Standing charge" to "£12.30", "Energy used" to "£71.87", "Amount due" to AMOUNT)
    secondTotal?.let { rows += "Total to pay" to it }
    var amountBox: Rect? = null
    for ((label, value) in rows) {
      c.drawText(label, left, y, body)
      val x = right - body.measureText(value)
      c.drawText(value, x, y, body)
      if (value == AMOUNT && label == "Amount due") {
        val bounds = Rect()
        body.getTextBounds(value, 0, value.length, bounds)
        amountBox = Rect((x + bounds.left).toInt(), (y + bounds.top).toInt(), (x + bounds.right).toInt(), (y + bounds.bottom).toInt())
        smudgeDigit?.let { i ->
          val start = x + body.measureText(value, 0, i)
          val end = x + body.measureText(value, 0, i + 1)
          pixelate(bitmap, Rect(start.toInt(), (y + bounds.top).toInt() - 2, end.toInt() + 1, (y + bounds.bottom).toInt() + 2), block = 9)
        }
      }
      y += 40f
    }
    check(amountBox != null)

    c.drawText("Please pay the amount due by 24 November 2026.", left, y + 40f, body)
    c.drawText("Yours sincerely,", left, y + 130f, body)
    c.drawText("Sam Lee", left, y + 210f, body)
    c.drawText("Customer Services", left, y + 248f, body)
    return bitmap
  }

  /** Replaces [r] with flat blocks of its average colour: a digit that can't be made out. */
  private fun pixelate(bitmap: Bitmap, r: Rect, block: Int) {
    var by = r.top
    while (by < r.bottom) {
      var bx = r.left
      while (bx < r.right) {
        val x1 = minOf(bx + block, r.right)
        val y1 = minOf(by + block, r.bottom)
        var sum = 0L
        var n = 0
        for (yy in by until y1) for (xx in bx until x1) {
          sum += Color.red(bitmap.getPixel(xx, yy))
          n++
        }
        val g = (sum / maxOf(n, 1)).toInt()
        for (yy in by until y1) for (xx in bx until x1) bitmap.setPixel(xx, yy, Color.rgb(g, g, g))
        bx += block
      }
      by += block
    }
  }
}
