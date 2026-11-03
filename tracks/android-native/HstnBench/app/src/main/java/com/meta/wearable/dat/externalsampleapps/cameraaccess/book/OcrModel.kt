// OcrModel - engine-neutral OCR result
//
// Plain data the book core works on, so layout, framing and dedup run as JVM unit tests without
// ML Kit or Android. MlKitOcr converts ML Kit's Text into this; tests build it by hand.
// Coordinates are image pixels, origin top-left.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.book

data class Box(val left: Float, val top: Float, val right: Float, val bottom: Float) {
  val width: Float
    get() = right - left

  val height: Float
    get() = bottom - top

  val centerX: Float
    get() = (left + right) / 2f

  val centerY: Float
    get() = (top + bottom) / 2f

  fun union(other: Box): Box =
      Box(
          minOf(left, other.left),
          minOf(top, other.top),
          maxOf(right, other.right),
          maxOf(bottom, other.bottom),
      )
}

/** One recognised line. [confidence] is 0..1, or null when the engine doesn't report it. */
data class OcrLine(val text: String, val box: Box, val confidence: Float? = null)

/** A block of lines as the engine grouped them. The layout code mostly works on lines. */
data class OcrBlock(val lines: List<OcrLine>)

data class OcrPage(val imageWidth: Int, val imageHeight: Int, val blocks: List<OcrBlock>) {
  val lines: List<OcrLine>
    get() = blocks.flatMap { it.lines }

  /** Raw engine text in engine order, one line per line. Used for scoring raw OCR. */
  val rawText: String
    get() = lines.joinToString("\n") { it.text }

  companion object {
    /** Convenience for tests: every line in its own block. */
    fun ofLines(imageWidth: Int, imageHeight: Int, lines: List<OcrLine>): OcrPage =
        OcrPage(imageWidth, imageHeight, lines.map { OcrBlock(listOf(it)) })
  }
}
