/*
 * LabelsVision - barcodes on the phone with Apple Vision, and the barcode-like hint when none decodes
 *
 * VNDetectBarcodesRequest replaces Android's ML Kit. It runs on the phone; nothing leaves it.
 * Product symbologies (EAN-13, EAN-8, UPC-E; Vision reports UPC-A as EAN-13 with a leading 0) can
 * be looked up; QR codes are described (LabelCodes.describeQr); anything else is read as digits.
 * When nothing decodes, BarcodeHint looks for bars in 48 rows of a 480 px greyscale copy, for the
 * geiger ticks. Blocking; call off the main actor.
 */

import UIKit
import Vision

enum LabelsVision {
  static let symbologies: [VNBarcodeSymbology] = [
    .ean13, .ean8, .upce, .qr, .code128, .code39, .code93, .itf14, .i2of5, .dataMatrix, .pdf417, .aztec, .codabar,
  ]

  /// The first decoded code in `image`, or (if none) a barcode-like patch.
  static func scan(_ image: UIImage) -> (code: ScannedCode?, hint: BarRegion?) {
    if let code = decode(image) { return (code, nil) }
    guard let rows = ToolImageSampler.lumaRows(image) else { return (nil, nil) }
    return (nil, BarcodeHint.find(rows.luma, width: rows.width, rows: rows.rows))
  }

  static func decode(_ image: UIImage) -> ScannedCode? {
    guard let cgImage = image.cgImage else { return nil }
    let request = VNDetectBarcodesRequest()
    request.symbologies = symbologies
    let handler = VNImageRequestHandler(cgImage: cgImage, orientation: CGImagePropertyOrientation(image.imageOrientation))
    do {
      try handler.perform([request])
    } catch {
      return nil
    }
    // Prefer a valid product code, then a QR code, then anything readable.
    let codes = (request.results ?? []).compactMap(scannedCode)
    return codes.first { $0.productCode != nil } ?? codes.first { $0.kind == .qr } ?? codes.first { $0.kind != .product }
  }

  private static func scannedCode(_ observation: VNBarcodeObservation) -> ScannedCode? {
    guard let payload = observation.payloadStringValue, !payload.isEmpty else { return nil }
    switch observation.symbology {
    case .ean13: return ScannedCode(raw: payload, kind: .product, format: "EAN-13")
    case .ean8: return ScannedCode(raw: payload, kind: .product, format: "EAN-8")
    case .upce: return ScannedCode(raw: payload, kind: .product, format: "UPC-E")
    case .qr: return ScannedCode(raw: payload, kind: .qr, format: "QR")
    default: return ScannedCode(raw: payload, kind: .other, format: "barcode")
    }
  }
}
