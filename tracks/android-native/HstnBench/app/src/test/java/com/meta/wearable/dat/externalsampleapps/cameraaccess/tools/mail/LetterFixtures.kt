// LetterFixtures - OCR results for realistic letters, built by hand, for the mail reader's JVM tests
//
// Each fixture places lines where they sit on a 960x1440 photo of an A4 letter, grouped into the
// blocks ML Kit makes (letterhead, address, date, heading, paragraphs, a table of charges,
// signature), with word and character confidences. Body text is 24 px high; a letterhead is
// bigger. [low] marks single characters as read with low confidence, the way a smudged or blurred
// digit comes back from ML Kit.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.mail

import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.Box

class LetterBuilder(private val width: Int = 960, private val height: Int = 1440) {
  private val lines = mutableListOf<LetterLine>()
  private var block = 0

  /** Starts a new ML Kit block. */
  fun block(body: LetterBuilder.() -> Unit) {
    this.body()
    block++
  }

  /**
   * A line at ([x], [y]) of text height [h]. Width from the text (about 0.5 h per character).
   * [low]: character index in the line -> confidence, for smudged characters.
   */
  fun line(text: String, x: Float, y: Float, h: Float = 24f, conf: Float = 0.95f, low: Map<Int, Float> = emptyMap()) {
    val w = text.length * h * 0.5f
    var at = 0
    val words =
        text.split(' ').filter { it.isNotEmpty() }.map { word ->
          val start = text.indexOf(word, at)
          at = start + word.length
          val symbols = word.indices.map { i -> low[start + i] ?: conf }
          LetterWord(word, symbols.minOrNull() ?: conf, symbols)
        }
    lines += LetterLine(text, Box(x, y, x + w, y + h), block, conf, words)
  }

  fun build(): LetterScan = LetterScan(width, height, lines.toList())
}

fun letter(body: LetterBuilder.() -> Unit): LetterScan = LetterBuilder().apply(body).build()

object LetterFixtures {

  /** An electricity bill: letterhead, window address, account number, heading, a table, a due date. */
  fun utilityBill(amountDue: String = "£84.17", amountLow: Map<Int, Float> = emptyMap(), secondTotal: String? = null): LetterScan = letter {
    block { line("Northgate Energy", 80f, 70f, h = 48f) }
    block {
      line("PO Box 512, Leeds LS1 4AB", 560f, 80f, h = 18f)
      line("0800 123 4567", 560f, 104f, h = 18f)
    }
    block {
      line("Mrs Jane Patel", 80f, 250f)
      line("14 Elm Road", 80f, 282f)
      line("Leeds", 80f, 314f)
      line("LS6 2AB", 80f, 346f)
    }
    block {
      line("Account number: 8842 1937 55", 520f, 250f, h = 20f)
      line("3 November 2026", 520f, 280f, h = 20f)
    }
    block { line("Your electricity bill", 80f, 450f, h = 34f) }
    block { line("Dear Mrs Patel,", 80f, 520f) }
    block {
      line("Here is your bill for the period 1 October to 31 October 2026. Your", 80f, 570f)
      line("Direct Debit is not set up, so please pay by bank transfer or by", 80f, 602f)
      line("phone using the account number above.", 80f, 634f)
    }
    block {
      line("Standing charge", 80f, 700f)
      line("Energy used (412 kWh)", 80f, 732f)
      line("Amount due", 80f, 764f)
    }
    block {
      line("£12.30", 760f, 700f)
      line("£71.87", 760f, 732f)
      line(amountDue, 760f, 764f, low = amountLow)
    }
    block {
      line("Please pay the amount due by 24 November 2026.", 80f, 830f)
      if (secondTotal != null) line("Total to pay $secondTotal", 80f, 862f)
    }
    block {
      line("Yours sincerely,", 80f, 940f)
      line("Sam Lee", 80f, 1010f)
      line("Customer Services", 80f, 1042f)
    }
  }

  /** A bank writing about account changes: a "Re:" line, sort code, a balance that isn't owed. */
  val bankLetter: LetterScan = letter {
    block { line("Harbour Bank", 80f, 70f, h = 52f) }
    block {
      line("Mr Tom Reid", 80f, 250f)
      line("7 Quay Street", 80f, 282f)
      line("Whitby", 80f, 314f)
      line("YO21 3PU", 80f, 346f)
    }
    block { line("28 October 2026", 640f, 250f, h = 20f) }
    block { line("Re: Changes to your current account", 80f, 440f) }
    block { line("Dear Mr Reid,", 80f, 500f) }
    block {
      line("We are writing to let you know about changes to your current account,", 80f, 550f)
      line("sort code 20-45-77, account ending 4471. From 1 January 2027 the", 80f, 582f)
      line("arranged overdraft interest rate will change to 39.9% EAR. Your", 80f, 614f)
      line("balance on 27 October was £1,240.50. You don't need to do anything.", 80f, 646f)
    }
    block {
      line("Yours sincerely,", 80f, 740f)
      line("Priya Shah", 80f, 800f)
      line("Head of Current Accounts", 80f, 832f)
    }
  }

  /** A council tax bill: official, an amount payable and the first instalment date. */
  val councilTax: LetterScan = letter {
    block { line("Riverside Borough Council", 80f, 70f, h = 44f) }
    block {
      line("Mr Ahmed Khan", 80f, 250f)
      line("Flat 3, 22 Mill Lane", 80f, 282f)
      line("Riverside", 80f, 314f)
      line("RV4 9TT", 80f, 346f)
    }
    block {
      line("Council tax reference: 6003 4471 2", 520f, 250f, h = 20f)
      line("Date: 1 November 2026", 520f, 280f, h = 20f)
    }
    block { line("Council Tax Bill 2026/27", 80f, 440f, h = 34f) }
    block { line("Dear Mr Khan,", 80f, 510f) }
    block {
      line("Your property is in valuation band C. The council tax for the year", 80f, 560f)
      line("is shown below. You can pay in 10 monthly instalments of £168.40.", 80f, 592f)
    }
    block {
      line("Amount payable", 80f, 660f)
      line("First instalment due", 80f, 692f)
    }
    block {
      line("£1,684.00", 740f, 660f)
      line("1 December 2026", 680f, 692f)
    }
    block {
      line("Yours faithfully,", 80f, 780f)
      line("Revenues Manager", 80f, 840f)
    }
  }

  /** A handwritten-style personal letter: sender's address top right, no letterhead, "Lots of love". */
  val personal: LetterScan = letter {
    block {
      line("12 Oak Lane", 620f, 70f)
      line("Bristol", 620f, 102f)
      line("BS8 1QU", 620f, 134f)
    }
    block { line("2 November 2026", 620f, 190f) }
    block { line("Dear Jane,", 80f, 280f) }
    block {
      line("I hope you are well and that the new flat is warming up now that the", 80f, 330f)
      line("weather has turned. We had a lovely week in Cornwall and I thought of", 80f, 362f)
      line("you when we walked past the little bookshop in St Ives.", 80f, 394f)
    }
    block {
      line("Do come and visit soon. I miss you and can't wait to see you.", 80f, 450f)
    }
    block {
      line("Lots of love,", 80f, 530f)
      line("Margaret", 80f, 590f)
    }
  }

  /** A shop flyer addressed to the occupier. */
  val flyer: LetterScan = letter {
    block { line("MEGA SOFA SALE!", 80f, 80f, h = 72f) }
    block { line("50% off everything, today only!", 80f, 220f, h = 40f) }
    block {
      line("The Occupier", 80f, 330f)
      line("14 Elm Road", 80f, 362f)
      line("Leeds LS6 2AB", 80f, 394f)
    }
    block {
      line("Free delivery and a free footstool voucher for new customers.", 80f, 480f)
      line("Visit our showroom or call now on 0800 555 0101. Don't miss out!", 80f, 512f)
    }
    block { line("Prices from £299", 80f, 600f, h = 40f) }
  }

  /** The front of a window envelope: the address, a return address, postage paid. */
  val windowEnvelope: LetterScan = letter {
    block { line("If undelivered please return to: Northgate Energy, PO Box 512, Leeds LS1 4AB", 60f, 60f, h = 14f) }
    block {
      line("Royal Mail", 760f, 60f, h = 16f)
      line("Postage Paid GB", 760f, 80f, h = 16f)
    }
    block {
      line("Mrs Jane Patel", 120f, 420f)
      line("14 Elm Road", 120f, 452f)
      line("Leeds", 120f, 484f)
      line("LS6 2AB", 120f, 516f)
    }
  }

  /** A hospital appointment letter. */
  val appointment: LetterScan = letter {
    block { line("Leeds Teaching Hospitals NHS Trust", 80f, 70f, h = 40f) }
    block {
      line("Ms Rosa Lind", 80f, 250f)
      line("5 Park View", 80f, 282f)
      line("Leeds LS2 7EE", 80f, 314f)
    }
    block {
      line("NHS number: 485 777 3456", 560f, 250f, h = 20f)
      line("30 October 2026", 560f, 280f, h = 20f)
    }
    block { line("Dear Ms Lind,", 80f, 420f) }
    block {
      line("Your outpatient appointment is on Tuesday 8 December 2026 at 10:30am", 80f, 470f)
      line("in the Eye Clinic, Chapel Allerton Hospital. Please bring your glasses.", 80f, 502f)
    }
    block {
      line("Yours sincerely,", 80f, 580f)
      line("Outpatient Bookings", 80f, 640f)
    }
  }

  /** Page 2 of the utility bill when the first page had no amount. */
  val billPageOneNoAmount: LetterScan = letter {
    block { line("Northgate Energy", 80f, 70f, h = 48f) }
    block {
      line("Mrs Jane Patel", 80f, 250f)
      line("14 Elm Road", 80f, 282f)
      line("Leeds LS6 2AB", 80f, 314f)
    }
    block { line("3 November 2026", 600f, 250f, h = 20f) }
    block { line("Dear Mrs Patel,", 80f, 420f) }
    block {
      line("Your new tariff starts this month. The details of your charges are", 80f, 470f)
      line("on the next page, with how and when to pay.", 80f, 502f)
    }
  }

  val billPageTwo: LetterScan = letter {
    block {
      line("Standing charge", 80f, 100f)
      line("Amount due", 80f, 132f)
    }
    block {
      line("£12.30", 760f, 100f)
      line("£84.17", 760f, 132f)
    }
    block { line("Please pay by 24 November 2026.", 80f, 200f) }
    block {
      line("Yours sincerely,", 80f, 300f)
      line("Sam Lee", 80f, 360f)
    }
  }
}
