// MlKitBarcodes - on-device barcode decoding for the label reader
//
// ML Kit Barcode Scanning with the model bundled in the APK (com.google.mlkit:barcode-scanning, no
// Play Services download), so it works offline and no frame leaves the phone. Product formats
// (EAN-13/8, UPC-A/E) and QR are asked for first; other 1D codes are reported as "not a product
// barcode". Also samples a frame into the rows BarcodeHint looks at for the search ticks.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.labels

import android.graphics.Bitmap
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import java.io.Closeable
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine

class MlKitBarcodes : Closeable {

  private val scanner =
      BarcodeScanning.getClient(
          BarcodeScannerOptions.Builder()
              .setBarcodeFormats(
                  Barcode.FORMAT_EAN_13,
                  Barcode.FORMAT_EAN_8,
                  Barcode.FORMAT_UPC_A,
                  Barcode.FORMAT_UPC_E,
                  Barcode.FORMAT_QR_CODE,
                  Barcode.FORMAT_CODE_128,
                  Barcode.FORMAT_CODE_39,
                  Barcode.FORMAT_ITF,
                  Barcode.FORMAT_DATA_MATRIX,
              )
              .build(),
      )

  /** The best code in [bitmap] (a product code over a QR code over anything else), or null. */
  suspend fun scan(bitmap: Bitmap): ScannedCode? = suspendCancellableCoroutine { cont ->
    scanner
        .process(InputImage.fromBitmap(bitmap, 0))
        .addOnSuccessListener { codes ->
          val found = codes.mapNotNull(::toCode)
          cont.resume(
              found.firstOrNull { it.kind == CodeKind.PRODUCT && it.productCode != null }
                  ?: found.firstOrNull { it.kind == CodeKind.QR }
                  ?: found.firstOrNull { it.kind == CodeKind.OTHER },
          )
        }
        .addOnFailureListener { cont.resumeWithException(it) }
  }

  override fun close() = scanner.close()

  companion object {
    private fun toCode(b: Barcode): ScannedCode? {
      val raw = b.rawValue ?: b.displayValue ?: return null
      return when (b.format) {
        Barcode.FORMAT_EAN_13 -> ScannedCode(raw, CodeKind.PRODUCT, "EAN-13")
        Barcode.FORMAT_EAN_8 -> ScannedCode(raw, CodeKind.PRODUCT, "EAN-8")
        Barcode.FORMAT_UPC_A -> ScannedCode(raw, CodeKind.PRODUCT, "UPC-A")
        Barcode.FORMAT_UPC_E -> ScannedCode(raw, CodeKind.PRODUCT, "UPC-E")
        Barcode.FORMAT_QR_CODE -> ScannedCode(raw, CodeKind.QR, "QR")
        Barcode.FORMAT_DATA_MATRIX -> ScannedCode(raw, CodeKind.OTHER, "Data Matrix")
        else -> ScannedCode(raw, CodeKind.OTHER, "barcode")
      }
    }

    /** Rows for BarcodeHint: [rows] full-width rows (at most 640 samples wide), evenly spaced. */
    fun hintRows(bitmap: Bitmap, rows: Int = 48): Triple<IntArray, Int, Int> {
      val step = (bitmap.width + 639) / 640
      val w = bitmap.width / step
      val luma = IntArray(w * rows)
      val line = IntArray(bitmap.width)
      for (r in 0 until rows) {
        val y = (r * bitmap.height / rows + bitmap.height / (2 * rows)).coerceIn(0, bitmap.height - 1)
        bitmap.getPixels(line, 0, bitmap.width, 0, y, bitmap.width, 1)
        for (x in 0 until w) {
          val c = line[x * step]
          luma[r * w + x] = (299 * ((c shr 16) and 0xff) + 587 * ((c shr 8) and 0xff) + 114 * (c and 0xff)) / 1000
        }
      }
      return Triple(luma, w, rows)
    }
  }
}
