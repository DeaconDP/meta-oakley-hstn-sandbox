// MailOcr - on-device text recognition for the mail reader
//
// The same ML Kit Text Recognition v2 (Latin, bundled model, offline) as the book reader's
// MlKitOcr, but it keeps more of the result: the block each line came from, and the confidence of
// every word and every character, which the money rule needs (one unsure digit and the amount is
// not spoken). Converts ML Kit's Text into the pure LetterScan. Nothing leaves the phone.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.mail

import android.graphics.Bitmap
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.Text
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.Box
import java.io.Closeable
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine

class MailOcr : Closeable {

  private val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)

  suspend fun recognize(bitmap: Bitmap): LetterScan = suspendCancellableCoroutine { cont ->
    recognizer
        .process(InputImage.fromBitmap(bitmap, 0))
        .addOnSuccessListener { text -> cont.resume(toScan(text, bitmap.width, bitmap.height)) }
        .addOnFailureListener { error -> cont.resumeWithException(error) }
  }

  override fun close() {
    recognizer.close()
  }

  companion object {
    // ML Kit reports 0 when it has no score; that means unknown, not "certainly wrong".
    private fun score(c: Float): Float? = c.takeIf { it > 0f }

    fun toScan(text: Text, width: Int, height: Int): LetterScan {
      val lines = mutableListOf<LetterLine>()
      text.textBlocks.forEachIndexed { b, block ->
        for (line in block.lines) {
          val r = line.boundingBox ?: continue
          val words =
              line.elements.map { e ->
                val symbols = e.symbols.mapNotNull { s -> score(s.confidence) }
                LetterWord(
                    text = e.text,
                    confidence = score(e.confidence),
                    symbolConfidences = if (symbols.size == e.text.length) symbols else emptyList(),
                )
              }
          // Rebuild the line from its words when ML Kit dropped the spaces (see MlKitOcr).
          val lineText =
              if (words.size >= 2 && line.text.count { it == ' ' } < words.size - 1) words.joinToString(" ") { it.text }
              else line.text
          lines +=
              LetterLine(
                  text = lineText,
                  box = Box(r.left.toFloat(), r.top.toFloat(), r.right.toFloat(), r.bottom.toFloat()),
                  block = b,
                  confidence = score(line.confidence),
                  words = words,
              )
        }
      }
      return LetterScan(width, height, lines)
    }
  }
}
