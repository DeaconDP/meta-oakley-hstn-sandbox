// MlKitOcr - on-device text recognition for the book reader
//
// ML Kit Text Recognition v2, Latin script, with the model bundled in the APK
// (com.google.mlkit:text-recognition), so it works offline and nothing leaves the phone (ROADMAP
// privacy rule). Converts ML Kit's Text into the engine-neutral OcrPage the book core works on.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.bookreader

import android.graphics.Bitmap
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.Text
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.Box
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.OcrBlock
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.OcrLine
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.OcrPage
import java.io.Closeable
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine

class MlKitOcr : Closeable {

  private val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)

  suspend fun recognize(bitmap: Bitmap): OcrPage = suspendCancellableCoroutine { cont ->
    recognizer
        .process(InputImage.fromBitmap(bitmap, 0))
        .addOnSuccessListener { text -> cont.resume(toPage(text, bitmap.width, bitmap.height)) }
        .addOnFailureListener { error -> cont.resumeWithException(error) }
  }

  override fun close() {
    recognizer.close()
  }

  companion object {
    /**
     * On some justified lines ML Kit drops word spaces from Line.text ("TheTimeTravellerwas...").
     * When its elements still split the words, rebuild the line from them. When the element is
     * merged too, nothing reliable is left: per-character boxes are too loose to find word gaps
     * (tried; it split "breakfa st"), so the line is read as returned.
     */
    private fun lineText(line: Text.Line): String {
      val elements = line.elements
      if (elements.size < 2 || line.text.count { it == ' ' } >= elements.size - 1) return line.text
      return elements.joinToString(" ") { it.text }
    }

    fun toPage(text: Text, width: Int, height: Int): OcrPage =
        OcrPage(
            width,
            height,
            text.textBlocks.map { block ->
              OcrBlock(
                  block.lines.mapNotNull { line ->
                    val r = line.boundingBox ?: return@mapNotNull null
                    OcrLine(
                        text = lineText(line),
                        box = Box(r.left.toFloat(), r.top.toFloat(), r.right.toFloat(), r.bottom.toFloat()),
                        // ML Kit reports 0 when it has no score; treat that as unknown.
                        confidence = line.confidence.takeIf { it > 0f },
                    )
                  },
              )
            },
        )
  }
}
