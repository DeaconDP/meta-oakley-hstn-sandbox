// FramingCheck - spoken framing guidance from OCR box geometry
//
// Runs on the OCR result before anything is read, so a page that is cut off, blurred or too far
// away gets a hint instead of a garbled reading (ROADMAP ground rule: say when unsure). Text boxes
// pressed against an image edge mean the page continues past it.
//
// Direction words are for a head-worn camera: to see more of the right side of the page, turn your
// head right. HSTN's camera sits on the left of the frame, so when the reader looks straight at the
// book the camera's view is shifted left and the right side of the page is the edge that gets cut
// off most. That is why the right edge uses the lowest line-count threshold.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.book

enum class FramingIssue {
  NO_TEXT,
  LOW_CONFIDENCE,
  TOO_SMALL,
  CUT_LEFT,
  CUT_RIGHT,
  CUT_TOP,
  CUT_BOTTOM,
  TOO_CLOSE,
}

data class FramingResult(val issues: List<FramingIssue>, val hint: String?) {
  val isOk: Boolean
    get() = issues.isEmpty()

  /** Unreadable (as opposed to readable but cut off): there's nothing worth reading yet. */
  val isUnreadable: Boolean
    get() =
        FramingIssue.NO_TEXT in issues ||
            FramingIssue.LOW_CONFIDENCE in issues ||
            FramingIssue.TOO_SMALL in issues
}

object FramingCheck {

  data class Options(
      /** A box within this fraction of the width/height of an edge is touching it. */
      val edgeMargin: Float = 0.015f,
      val minChars: Int = 12,
      val minMeanConfidence: Float = 0.55f,
      /** Median line height below this many pixels is too small for reliable OCR. */
      val minLineHeightPx: Float = 12f,
      /** Lines touching the right edge needed to call it cut off (lowest: the camera is left). */
      val minRightEdgeLines: Int = 2,
      val minLeftEdgeLines: Int = 3,
      /** And at least this fraction of all lines. */
      val minSideEdgeFraction: Float = 0.2f,
  )

  fun check(page: OcrPage, options: Options = Options()): FramingResult {
    val lines = page.lines.filter { it.text.isNotBlank() }
    val chars = lines.sumOf { it.text.count { c -> c.isLetterOrDigit() } }
    if (lines.isEmpty() || chars < options.minChars) return result(listOf(FramingIssue.NO_TEXT))

    val confidences = lines.mapNotNull { it.confidence }
    if (confidences.isNotEmpty() && confidences.average() < options.minMeanConfidence) {
      return result(listOf(FramingIssue.LOW_CONFIDENCE))
    }
    if (PageLayout.median(lines.map { it.box.height }) < options.minLineHeightPx) {
      return result(listOf(FramingIssue.TOO_SMALL))
    }

    val w = page.imageWidth.toFloat()
    val h = page.imageHeight.toFloat()
    val mx = w * options.edgeMargin
    val my = h * options.edgeMargin
    val sideMin = { base: Int -> maxOf(base, (lines.size * options.minSideEdgeFraction).toInt()) }
    val left = lines.count { it.box.left <= mx } >= sideMin(options.minLeftEdgeLines)
    val right = lines.count { it.box.right >= w - mx } >= sideMin(options.minRightEdgeLines)
    val top = lines.any { it.box.top <= my }
    val bottom = lines.any { it.box.bottom >= h - my }

    val issues = mutableListOf<FramingIssue>()
    if ((left && right) || (top && bottom)) {
      issues += FramingIssue.TOO_CLOSE
    } else {
      if (right) issues += FramingIssue.CUT_RIGHT
      if (left) issues += FramingIssue.CUT_LEFT
      if (top) issues += FramingIssue.CUT_TOP
      if (bottom) issues += FramingIssue.CUT_BOTTOM
    }
    return result(issues)
  }

  private fun result(issues: List<FramingIssue>) = FramingResult(issues, hintFor(issues))

  fun hintFor(issues: List<FramingIssue>): String? {
    if (issues.isEmpty()) return null
    when {
      FramingIssue.NO_TEXT in issues ->
          return "Can't read this. Hold the book steady, a little closer."
      FramingIssue.LOW_CONFIDENCE in issues ->
          return "Can't read this clearly. Hold the book steady."
      FramingIssue.TOO_SMALL in issues -> return "The text is too small. Bring the book closer."
      FramingIssue.TOO_CLOSE in issues ->
          return "The page doesn't fit. Hold the book a little further away."
    }
    val where = mutableListOf<String>()
    val move = mutableListOf<String>()
    if (FramingIssue.CUT_RIGHT in issues) {
      where += "on the right"
      move += "turn your head right"
    }
    if (FramingIssue.CUT_LEFT in issues) {
      where += "on the left"
      move += "turn your head left"
    }
    if (FramingIssue.CUT_TOP in issues) {
      where += "at the top"
      move += "tilt your head up"
    }
    if (FramingIssue.CUT_BOTTOM in issues) {
      where += "at the bottom"
      move += "tilt your head down"
    }
    val action = move.joinToString(" and ").replaceFirstChar { it.uppercase() }
    return "Page cut off ${where.joinToString(" and ")}. $action."
  }
}
