// OnDeviceAsk - answering questions about the text on the phone, with no cloud model
//
// The main path, not a fallback: the user has no API key. AskGrammar says what kind of question it
// is; this answers it from the text read so far (ReadText) and the bundled dictionary:
//
//   define   "what does recondite mean"   WordLookup: the word in the text (or the closest one that
//                                          sounds like it: "Did you mean recondite?"), part of
//                                          speech, one or two senses; "more" for the rest; "no"
//                                          takes the word as heard.
//   spell    "spell it"                   the last word talked about, letter by letter.
//   who      "who is Holmes"              Mentions: first mention and the latest one or two.
//   what     "what's the Time Machine"    a name in the text if it's there, else the dictionary.
//   recap    "where did we leave off"     Recap: the last ~60 words read, or the end of the last
//                                          session (kept with the bookmark) if nothing's read yet.
//   find     "what did it say about X"    Search: matching sentences; "next" for the next one.
//   other    "why did he do that"         says what it can do, or (only if an API key is built in)
//                                          asks Claude with the recent text: [online].
//
// It never makes anything up: every answer is a quote from the text or a dictionary sense.
// Follow-ups are offered for two minutes (AskGrammar.FollowUps). Pure Kotlin, JVM-tested; Android
// wiring is in AskProvider. Called on the main dispatcher; the dictionary loads on IO (AskProvider).

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ask

import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.AskAboutText
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.AskResult
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.GlobalCommand
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.Phrases
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.RecentText
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId

/** An open question sent somewhere that can reason over the text (the optional Claude path). */
fun interface OnlineAsk {
  suspend fun ask(question: String, text: String): AskResult
}

class OnDeviceAsk(
    /** The dictionary, or null if it couldn't be loaded. May suspend while it loads. */
    private val dictionary: suspend () -> Dictionary?,
    /** The end of the last session's text (kept with the bookmark), read once at app start. */
    private val previousSession: () -> String? = { null },
    /** Null unless an API key was configured at build time. */
    private val online: OnlineAsk? = null,
) : AskAboutText {

  private var more = ArrayDeque<String>()
  private var lastWord: String? = null
  private var heardWord: String? = null
  private var hinted = false
  private var lookup: WordLookup? = null

  override suspend fun answer(question: GlobalCommand.Ask, text: RecentText.Snapshot?): AskResult =
      answer(question, text) {}

  override suspend fun answer(
      question: GlobalCommand.Ask,
      text: RecentText.Snapshot?,
      aside: (String) -> Unit,
  ): AskResult {
    val q = AskGrammar.classify(Phrases.normalize(question.question)) ?: AskQuestion(AskKind.OPEN, question.subject)
    val result = answerKind(q, question.question, text, aside)
    // "More"/"next" count for a while after any answer ("That's all I have." when there's no more).
    if (result is AskResult.Answer) AskGrammar.FollowUps.open(more = true, no = heardWord != null)
    else AskGrammar.FollowUps.close()
    if (result is AskResult.Answer && !hinted && text?.tool == ToolId.BOOK && text.current != null && q.kind != AskKind.MORE) {
      hinted = true
      return AskResult.Answer(result.text + " " + AskWording.CARRY_ON_HINT)
    }
    return result
  }

  private suspend fun answerKind(q: AskQuestion, asked: String, text: RecentText.Snapshot?, aside: (String) -> Unit): AskResult {
    val current = ReadText.sentences(text)
    val previous = previousSession()?.let(Sentences::split).orEmpty()
    val usePrevious = current.isEmpty() && previous.isNotEmpty()
    val corpus = if (usePrevious) previous else current
    if (q.kind != AskKind.MORE && q.kind != AskKind.NO && q.kind != AskKind.SPELL) heardWord = null
    return when (q.kind) {
      AskKind.MORE -> more.removeFirstOrNull()?.let { AskResult.Answer(it) } ?: AskResult.Answer(AskWording.NOTHING_MORE)
      AskKind.NO -> {
        val heard = heardWord ?: return AskResult.Answer(AskWording.NOTHING_TO_UNDO)
        heardWord = null
        define(heard, corpus, allowCorrection = false)
      }
      AskKind.DEFINE -> define(q.subject.orEmpty(), corpus, allowCorrection = true)
      AskKind.SPELL -> spell(q.subject, corpus)
      AskKind.WHO ->
          if (corpus.isEmpty()) AskResult.NothingRead
          else who(q.subject.orEmpty(), corpus, usePrevious)
              ?: AskResult.Answer(AskWording.notReadAbout(AskWording.spokenName(q.subject.orEmpty())))
      AskKind.WHAT -> {
        who(q.subject.orEmpty(), corpus, usePrevious)?.let { return it }
        val dict = dictionary()
        if (dict != null && Lemmatiser(dict).lemma(q.subject.orEmpty()) != null) define(q.subject.orEmpty(), corpus, allowCorrection = false)
        else if (corpus.isEmpty()) AskResult.NothingRead
        else AskResult.Answer(AskWording.notReadAbout(AskWording.spokenName(q.subject.orEmpty())))
      }
      AskKind.RECAP -> {
        val from = if (current.isNotEmpty()) current else previous
        if (from.isEmpty()) return AskResult.NothingRead
        more.clear()
        AskResult.Answer(AskWording.recap(Recap.last(from), lastTime = from === previous))
      }
      AskKind.FIND -> find(q.subject.orEmpty(), corpus)
      AskKind.OPEN -> {
        more.clear()
        val o = online ?: return AskResult.Answer(AskWording.CAN_ONLY)
        if (corpus.isEmpty()) return AskResult.NothingRead
        aside(AskWording.ASKING_ONLINE)
        o.ask(asked, corpus.joinToString(" ").takeLast(ONLINE_MAX_CHARS))
      }
    }
  }

  private suspend fun wordLookup(): WordLookup? {
    lookup?.let { return it }
    val dict = dictionary() ?: return null
    return WordLookup(dict).also { lookup = it }
  }

  private suspend fun define(heard: String, corpus: List<String>, allowCorrection: Boolean): AskResult {
    val wl = wordLookup() ?: return AskResult.Answer(AskWording.NOT_READY)
    val choice = wl.choose(heard, corpus, allowCorrection) ?: return AskResult.Answer(AskWording.NOTHING_TO_UNDO)
    val def = wl.define(choice.word)
    lastWord = choice.word
    more = ArrayDeque(def.more)
    if (choice.corrected) {
      heardWord = choice.heard
      return AskResult.Answer(AskWording.didYouMean(choice.word) + " " + def.text)
    }
    return AskResult.Answer(def.text)
  }

  private suspend fun spell(subject: String?, corpus: List<String>): AskResult {
    if (subject == null) return AskResult.Answer(lastWord?.let(AskWording::spell) ?: AskWording.NO_WORD_YET)
    val h = Lemmatiser.clean(subject)
    // Spell the text's word when that's what was meant ("spell recon dight" -> recondite).
    val word = wordLookup()?.let { wl -> wl.inText(h, corpus) ?: wl.closest(h, wl.vocabulary(corpus)) } ?: h
    lastWord = word
    more.clear()
    return AskResult.Answer(AskWording.spell(word))
  }

  private fun who(subject: String, corpus: List<String>, lastTime: Boolean): AskResult? {
    if (corpus.isEmpty()) return null
    val found = Mentions.find(corpus, subject)
    if (found.isEmpty()) return null
    val name = Mentions.displayName(corpus, found, subject)
    val (text, rest) = AskWording.mentions(name, found, Mentions.keyWords(subject), lastTime)
    more = ArrayDeque(rest)
    return AskResult.Answer(text)
  }

  private fun find(subject: String, corpus: List<String>): AskResult {
    if (corpus.isEmpty()) return AskResult.NothingRead
    val found = Search.find(corpus, subject)
    if (found.isEmpty()) {
      more.clear()
      return AskResult.Answer(AskWording.nothingFound(subject))
    }
    val (text, rest) = AskWording.matches(subject, found, Search.keyWords(subject))
    more = ArrayDeque(rest)
    return AskResult.Answer(text)
  }

  companion object {
    /** At most this much recent text goes to the online path (about 2 500 words). */
    const val ONLINE_MAX_CHARS = 12_000
  }
}
