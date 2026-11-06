// LetterSpeech - what the mail reader says about a letter
//
// The short summary ("A bill from Northgate Energy, for Mrs Jane Patel. ... Amount due: £84.17, by
// 24 November 2026."), the envelope line ("This is the outside of an envelope, addressed to ...,
// from ..."), and the answers to "who's it from", "how much", "when is it due", "is it junk",
// "what's the reference". Unsure or conflicting amounts are never spoken as figures: the line asks
// for a closer look instead. Reference numbers are spelled out one character at a time. English
// only for now, like the book's FramingCheck hints. Pure Kotlin.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.mail

object LetterSpeech {

  const val UNSURE_AMOUNT =
      "There's an amount to pay, but I can't read it for sure. Hold the letter a little closer and keep it still, then say how much."
  const val CONFLICTING_AMOUNTS =
      "I can see two different amounts to pay, so I can't say which is right. Hold the letter a little closer, then say how much."
  const val NOT_SURE_FIGURE = "an amount I can't read for sure"

  fun kindPhrase(letter: Letter): String =
      when (letter.kind) {
        LetterKind.BILL -> "a bill"
        LetterKind.BANK -> "a letter from a bank"
        LetterKind.OFFICIAL -> "an official letter"
        LetterKind.MEDICAL -> "a medical letter"
        LetterKind.PERSONAL -> "a personal letter"
        LetterKind.ADVERT -> "an advert, probably junk mail"
        LetterKind.UNKNOWN -> "a letter"
      }

  fun summary(letter: Letter): String {
    if (letter.isEnvelope) return envelope(letter)
    val parts = mutableListOf<String>()
    val pages = if (letter.pages.size > 1) "${letter.pages.size} pages. " else ""
    val who = buildString {
      append(pages)
      append(kindPhrase(letter).replaceFirstChar { it.uppercase() })
      letter.sender?.let { append(" from ").append(it) }
      (letter.recipient ?: letter.salutation)?.let { append(", for ").append(it) }
      append('.')
      if (letter.sender == null) append(" I can't see who it's from.")
    }
    parts += who
    letter.date?.let { parts += "Dated ${it.spoken()}." }
    when {
      letter.subject != null -> parts += "About: ${letter.subject.trimEnd('.')}."
      letter.opening != null -> parts += "It starts: ${letter.opening}"
    }
    parts += moneyAndDeadline(letter)
    parts += "Say read it all to hear every word."
    return parts.filter { it.isNotBlank() }.joinToString(" ")
  }

  private fun moneyAndDeadline(letter: Letter): String =
      when (val a = letter.amount) {
        is AmountDue.Sure -> {
          val label = if (a.isTotal) "Total" else "Amount due"
          val due = letter.due?.takeIf { it.kind == DueKind.PAY || it.kind == DueKind.OTHER }
          buildString {
            append("$label: ${a.money.spoken()}")
            if (due != null) append(if (due.sure) ", by ${due.spoken}" else ". The due date isn't clear")
            append('.')
            a.minimum?.let { append(" Minimum payment: ${it.spoken()}.") }
            letter.due?.takeIf { it.kind == DueKind.APPOINTMENT || it.kind == DueKind.REPLY }?.let { append(" ").append(deadline(it)) }
          }
        }
        AmountDue.Unsure -> UNSURE_AMOUNT
        AmountDue.Conflict -> CONFLICTING_AMOUNTS
        AmountDue.None -> letter.due?.let(::deadline).orEmpty()
      }

  private fun deadline(due: DueDate): String {
    if (!due.sure) return "There's a date in it I can't read for sure."
    return when (due.kind) {
      DueKind.PAY -> "Pay by ${due.spoken}."
      DueKind.REPLY -> "Reply by ${due.spoken}."
      DueKind.APPOINTMENT -> "Appointment: ${due.spoken}."
      DueKind.OTHER -> "Deadline: ${due.spoken}."
    }
  }

  fun envelope(letter: Letter): String = buildString {
    append("This is the outside of an envelope")
    val to = listOfNotNull(letter.recipient, letter.recipientAddress).joinToString(", ")
    if (to.isNotEmpty()) append(", addressed to ").append(to)
    letter.sender?.let { append(", from ").append(it) }
    append('.')
    if (letter.sender == null) append(" I can't see who it's from.")
    append(" Open it and hold up the letter, then say read.")
  }

  fun from(letter: Letter): String =
      letter.sender?.let { "It's from $it." } ?: "I can't see who it's from. Try holding the top of the letter in view and say read."

  fun forWhom(letter: Letter): String {
    val to = listOfNotNull(letter.recipient, letter.recipientAddress).joinToString(", ")
    return when {
      to.isNotEmpty() -> "It's addressed to $to."
      letter.salutation != null -> "It says Dear ${letter.salutation}."
      else -> "I can't see who it's for."
    }
  }

  fun howMuch(letter: Letter): String =
      when (val a = letter.amount) {
        is AmountDue.Sure ->
            buildString {
              append(if (a.isTotal) "The total is ${a.money.spoken()}." else "The amount due is ${a.money.spoken()}.")
              a.minimum?.let { append(" The minimum payment is ${it.spoken()}.") }
              letter.due?.takeIf { it.sure && (it.kind == DueKind.PAY || it.kind == DueKind.OTHER) }?.let { append(" Pay by ${it.spoken}.") }
            }
        AmountDue.Unsure -> "I can't read the amount for sure. Hold the letter a little closer and keep it still, then say how much again."
        AmountDue.Conflict -> CONFLICTING_AMOUNTS
        AmountDue.None ->
            if (letter.amountsMentioned > 0) {
              "I can't see an amount to pay. The letter mentions ${count(letter.amountsMentioned, "amount")}; say read it all to hear them."
            } else {
              "I can't see an amount to pay in this letter."
            }
      }

  fun whenDue(letter: Letter): String {
    val due = letter.due ?: return "I can't see a due date or deadline."
    return deadline(due)
  }

  fun isJunk(letter: Letter): String =
      when {
        letter.isEnvelope -> "I can only see the envelope. Open it and say read."
        letter.kind == LetterKind.ADVERT -> "It looks like an advert, so probably junk mail."
        letter.kind == LetterKind.UNKNOWN -> "I'm not sure. It doesn't look like a bill or an official letter. Say read it all to hear it."
        else -> "It doesn't look like junk. It's ${kindPhrase(letter)}."
      }

  fun kind(letter: Letter): String =
      if (letter.isEnvelope) envelope(letter) else "It's ${kindPhrase(letter)}" + (letter.sender?.let { " from $it" } ?: "") + "."

  fun date(letter: Letter): String = letter.date?.let { "It's dated ${it.spoken()}." } ?: "I can't see a date on it."

  fun references(letter: Letter): String {
    if (letter.references.isEmpty()) return "I can't see an account or reference number."
    return letter.references.take(3).joinToString(" ") { r -> r.spoken.replaceFirstChar { it.uppercase() } + "." }
  }

  /**
   * One paragraph made safe to read aloud: digit runs spaced out, and every amount that couldn't
   * be read for sure replaced by [NOT_SURE_FIGURE].
   */
  fun forReading(paragraph: String, unsureMoney: Set<String>): String {
    var t = paragraph
    for (tok in LetterText.money(paragraph).reversed()) {
      if (tok.money == null || tok.raw in unsureMoney) t = t.replaceRange(tok.range, NOT_SURE_FIGURE)
    }
    return LetterText.forSpeech(t)
  }

  private fun count(n: Int, word: String): String = if (n == 1) "one $word" else "$n ${word}s"
}
