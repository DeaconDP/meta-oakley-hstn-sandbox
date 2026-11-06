// AskAboutText - the seam for answering questions about text that was just read
//
// "What does ephemeral mean?" while reading a book, "when is this due?" about a letter. GlobalGrammar
// (via tools/ask/AskGrammar) turns the question into GlobalCommand.Ask, and ToolHub calls
// [AskAboutText.answer] with the open tool's RecentText snapshot, then speaks the result. The
// ROADMAP plan is to send only that text and the question to Claude (Haiku 5.5), on request, never an
// image. Until that's built, tools/ask/AskProvider returns [NotReadyAskAboutText], which says "I
// can't answer questions yet." Pure Kotlin: the answer comes back as data and ToolHub picks the words.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core

sealed interface AskResult {
  /** Speak [text] as the answer. */
  data class Answer(val text: String) : AskResult

  /** The text that was read doesn't say. */
  data object NotInText : AskResult

  /** Nothing has been read yet, so there's nothing to ask about. */
  data object NothingRead : AskResult

  /** Questions aren't available (not built yet, no network, not allowed). */
  data object Unavailable : AskResult

  /** Something went wrong; [reason] is for the log, not for speaking. */
  data class Failed(val reason: String?) : AskResult
}

fun interface AskAboutText {
  /** Answers [question] (as the user said it) from [text], or says why it can't. */
  suspend fun answer(question: GlobalCommand.Ask, text: RecentText.Snapshot?): AskResult
}

/** The stub: always [AskResult.Unavailable] ("I can't answer questions yet."). */
object NotReadyAskAboutText : AskAboutText {
  override suspend fun answer(question: GlobalCommand.Ask, text: RecentText.Snapshot?): AskResult =
      AskResult.Unavailable
}
