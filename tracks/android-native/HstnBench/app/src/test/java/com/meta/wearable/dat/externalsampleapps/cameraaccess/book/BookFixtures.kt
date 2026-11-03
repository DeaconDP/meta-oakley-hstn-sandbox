// BookFixtures - OCR results shaped like real book captures
//
// Hand-built from the geometry ML Kit returns for a printed page: a running header in the top band,
// justified body lines, indented paragraph starts, short last lines, a page number at the foot.
// Text is public domain (Conan Doyle, The Hound of the Baskervilles; H. G. Wells, The Time Machine).

package com.meta.wearable.dat.externalsampleapps.cameraaccess.book

object BookFixtures {

  fun line(text: String, left: Float, top: Float, right: Float, height: Float = 24f, conf: Float = 0.92f) =
      OcrLine(text, Box(left, top, right, top + height), conf)

  // MARK: - Single portrait page (960x1440, the mock's in-stream capturePhoto size)

  const val PAGE_W = 960
  const val PAGE_H = 1440

  private const val BL = 90f // body left
  private const val BR = 870f // body right (justified)
  private const val IND = 130f // paragraph indent
  private const val TOP = 130f
  private const val PITCH = 34f

  private fun body(i: Int) = TOP + i * PITCH

  val houndLines: List<OcrLine> =
      listOf(
          line("THE HOUND OF THE BASKERVILLES", 300f, 60f, 660f, height = 20f),
          line("Mr. Sherlock Holmes, who was usually very late in the mornings,", IND, body(0), BR),
          line("save upon those not infrequent occasions when he was up all night,", BL, body(1), BR),
          line("was seated at the breakfast table. I stood upon the hearth-rug and", BL, body(2), BR),
          line("picked up the stick which our visitor had left behind him the night be-", BL, body(3), BR),
          line("fore. It was a fine, thick piece of wood, bulbous-headed, of the sort", BL, body(4), BR),
          line("which is known as a \"Penang lawyer.\"", BL, body(5), 500f),
          line("\"Well, Watson, what do you make of it?\"", IND, body(6), 560f),
          line("Holmes was sitting with his back to me, and I had given him no sign of my occu-", IND, body(7), BR),
          line("pation.", BL, body(8), 180f),
          line("3", 470f, 1360f, 490f, height = 22f),
      )

  val houndPage = OcrPage.ofLines(PAGE_W, PAGE_H, houndLines)

  val houndParagraphs =
      listOf(
          "Mr. Sherlock Holmes, who was usually very late in the mornings, save upon those not " +
              "infrequent occasions when he was up all night, was seated at the breakfast table. I " +
              "stood upon the hearth-rug and picked up the stick which our visitor had left behind " +
              "him the night before. It was a fine, thick piece of wood, bulbous-headed, of the sort " +
              "which is known as a \"Penang lawyer.\"",
          "\"Well, Watson, what do you make of it?\"",
          "Holmes was sitting with his back to me, and I had given him no sign of my occupation.",
      )

  // MARK: - Two-page spread (1440x960 landscape)

  const val SPREAD_W = 1440
  const val SPREAD_H = 960

  private const val LL = 60f
  private const val LR = 680f
  private const val RL = 760f
  private const val RR = 1380f
  private const val SP = 28f

  private fun row(i: Int) = 100f + i * SP

  val spreadLines: List<OcrLine> =
      listOf(
          // Running headers: the page number and title come back as separate OCR lines on one row.
          line("42", LL, 40f, 84f, height = 18f),
          line("THE TIME MACHINE", 290f, 40f, 450f, height = 18f),
          line("A STRANGE ARRIVAL", 980f, 40f, 1160f, height = 18f),
          line("43", 1356f, 40f, RR, height = 18f),
          // Left page. It opens mid-paragraph (no indent), continuing from page 41.
          line("The Time Traveller (for so it will be convenient to speak of him)", LL, row(0), LR, 20f),
          line("was expounding a recondite matter to us. His grey eyes shone and", LL, row(1), LR, 20f),
          line("twinkled, and his usually pale face was flushed and animated.", LL, row(2), 600f, 20f),
          line("\"You must follow me carefully. I shall have to controvert one or two", 90f, row(3), LR, 20f),
          line("ideas that are almost universally accepted. The geometry, for in-", LL, row(4), LR, 20f),
          line("stance, they taught you at school is founded on a misconception. It is extraor-", LL, row(5), LR, 20f),
          // Right page. The word broken at the bottom of page 42 finishes here.
          line("dinarily simple, and you will soon admit as much on reasonable grounds.\"", RL, row(0), 1300f, 20f),
          line("\"Is not that rather a large thing to expect us to begin upon?\" said Filby,", 790f, row(1), RR, 20f),
          line("an argumentative person with red hair.", RL, row(2), 1100f, 20f),
          line("\"I do not mean to ask you to accept anything without reasonable", 790f, row(3), RR, 20f),
          line("ground for it. You will soon admit as much as I need from you.\"", RL, row(4), 1320f, 20f),
      )

  // ML Kit returns lines roughly top to bottom across the whole image, interleaving the two pages.
  val spreadPage = OcrPage.ofLines(SPREAD_W, SPREAD_H, spreadLines.sortedBy { it.box.top })

  val spreadParagraphs =
      listOf(
          "The Time Traveller (for so it will be convenient to speak of him) was expounding a " +
              "recondite matter to us. His grey eyes shone and twinkled, and his usually pale face " +
              "was flushed and animated.",
          "\"You must follow me carefully. I shall have to controvert one or two ideas that are " +
              "almost universally accepted. The geometry, for instance, they taught you at school is " +
              "founded on a misconception. It is extraordinarily simple, and you will soon admit as " +
              "much on reasonable grounds.\"",
          "\"Is not that rather a large thing to expect us to begin upon?\" said Filby, an " +
              "argumentative person with red hair.",
          "\"I do not mean to ask you to accept anything without reasonable ground for it. You " +
              "will soon admit as much as I need from you.\"",
      )

  // MARK: - Variants

  /** The same page OCR'd again: a few character errors and the last body line missed. */
  val houndPageReOcr =
      OcrPage.ofLines(
          PAGE_W,
          PAGE_H,
          houndLines
              .filterNot { it.text == "pation." }
              .map { it.copy(text = it.text.replace("Holmes", "Hoimes").replace("thick", "tbick")) }
              .map { it.copy(box = it.box.copy(left = it.box.left + 6f, right = it.box.right + 6f)) },
      )

  /** The next page of the book, same layout. */
  val houndNextPage =
      OcrPage.ofLines(
          PAGE_W,
          PAGE_H,
          listOf(
              line("THE HOUND OF THE BASKERVILLES", 300f, 60f, 660f, height = 20f),
              line("\"How did you know what I was doing? I believe you have eyes in", IND, body(0), BR),
              line("the back of your head.\"", BL, body(1), 420f),
              line("\"I have, at least, a well-polished, silver-plated coffee-pot in front", IND, body(2), BR),
              line("of me,\" said he. \"But, tell me, Watson, what do you make of our", BL, body(3), BR),
              line("visitor's stick? Since we have been so unfortunate as to miss him and", BL, body(4), BR),
              line("have no notion of his errand, this accidental souvenir becomes of im-", BL, body(5), BR),
              line("portance. Let me hear you reconstruct the man by an examination of it.\"", BL, body(6), BR),
              line("4", 470f, 1360f, 490f, height = 22f),
          ),
      )

  /** Shifts every box right until the page's right edge runs off the image (camera on the left). */
  fun cutOffRight(page: OcrPage, overshoot: Float = 60f): OcrPage {
    val maxRight = page.lines.maxOf { it.box.right }
    val dx = page.imageWidth - maxRight + overshoot
    return OcrPage.ofLines(
        page.imageWidth,
        page.imageHeight,
        page.lines.map {
          it.copy(
              box =
                  it.box.copy(
                      left = it.box.left + dx,
                      right = minOf(it.box.right + dx, page.imageWidth.toFloat()),
                  ),
          )
        },
    )
  }
}
