// PageProcessor - one OCR'd capture in, one decision out
//
// The book loop's decision step without any Android: framing check, layout, "same page?", and the
// speech chunks. Also carries a word broken across captures ("exam-" at the bottom of page 12,
// "ple" at the top of page 13): the fragment is held back from page 12's speech and joined onto
// page 13's first word.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.book

sealed interface PageOutcome {
  /** Read this page. [framing] may still list a cut-off edge when the read was forced. */
  data class Read(
      val layout: PageLayoutResult,
      val paragraphs: List<String>,
      val chunks: List<SpeechChunk>,
      val framing: FramingResult,
  ) : PageOutcome {
    val displayText: String
      get() = paragraphs.joinToString("\n\n")
  }

  /** Don't read; speak [FramingResult.hint] and try again. */
  data class Hint(val framing: FramingResult) : PageOutcome

  /** The page already read is still in view. */
  data class SamePage(val similarity: Float) : PageOutcome
}

class PageProcessor(
    private val layoutOptions: PageLayout.Options = PageLayout.Options(),
    private val framingOptions: FramingCheck.Options = FramingCheck.Options(),
) {

  /** Body text of the last page read, for dedup. */
  var lastBodyText: String? = null
    private set

  /** Start of a word broken at the end of the last page, waiting for the next page. */
  var carry: String? = null
    private set

  /**
   * @param forceRead read even if the page is cut off (after repeated hints, or a manual request).
   *   An unreadable page (no text, low confidence) is never forced.
   */
  fun process(page: OcrPage, includeFurniture: Boolean, forceRead: Boolean = false): PageOutcome {
    val framing = FramingCheck.check(page, framingOptions)
    if (framing.isUnreadable) return PageOutcome.Hint(framing)

    val layout = PageLayout.layout(page, layoutOptions)
    val body = layout.bodyText()
    if (body.isBlank()) return PageOutcome.Hint(FramingResult(listOf(FramingIssue.NO_TEXT), FramingCheck.hintFor(listOf(FramingIssue.NO_TEXT))))
    if (PageDedup.isSamePage(lastBodyText, body)) {
      return PageOutcome.SamePage(PageDedup.similarity(lastBodyText!!, body))
    }
    if (!framing.isOk && !forceRead) return PageOutcome.Hint(framing)

    val paragraphs = layout.readingParagraphs(includeFurniture).toMutableList()
    val firstBody =
        if (includeFurniture) {
          layout.pages.firstOrNull()?.let { listOfNotNull(it.pageNumber, it.header).size } ?: 0
        } else {
          0
        }
    carry?.let { fragment ->
      if (firstBody < paragraphs.size) {
        val first = paragraphs[firstBody]
        paragraphs[firstBody] =
            if (first.firstOrNull()?.isLowerCase() == true) fragment + first else "$fragment $first"
      } else {
        paragraphs += fragment
      }
    }
    carry = null
    if (paragraphs.isNotEmpty() && PageLayout.endsWithBrokenWord(paragraphs.last())) {
      val last = paragraphs.last().trimEnd()
      val cut = last.lastIndexOf(' ')
      carry = last.substring(cut + 1).dropLast(1)
      val rest = if (cut > 0) last.substring(0, cut) else ""
      if (rest.isBlank()) paragraphs.removeAt(paragraphs.size - 1)
      else paragraphs[paragraphs.size - 1] = rest
    }

    lastBodyText = body
    return PageOutcome.Read(layout, paragraphs, SpeechChunker.chunk(paragraphs), framing)
  }

  /** Reading stopped: return the held-back fragment so it isn't silently lost. */
  fun flushCarry(): String? = carry.also { carry = null }

  fun reset() {
    lastBodyText = null
    carry = null
  }
}
