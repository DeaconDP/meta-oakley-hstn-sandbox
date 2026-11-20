/*
 * LabelCodes - what a decoded barcode is, and what to say about it
 *
 * Port of Android's tools/labels/Codes.kt. Vision gives a payload and a symbology. Product barcodes
 * (EAN-13, EAN-8, UPC-A, UPC-E) can be looked up; their check digit is verified first so a misread
 * never reaches Open Food Facts. QR codes are described, never opened: a web address is said as its
 * domain ("It links to example.com"), Wi-Fi codes give the network name but not the password, other
 * text is read (up to a sentence or two). Other 1D codes (shipping, shelf labels) are read as digits.
 */

import Foundation

enum ScannedCodeKind: Sendable {
  case product
  case qr
  case other
}

/// A decoded code. `format` is a short name ("EAN-13", "QR"), for the screen.
struct ScannedCode: Equatable, Sendable {
  var raw: String
  var kind: ScannedCodeKind
  var format: String

  /// The number to look up: digits, with UPC-A padded to 13. nil if it isn't a valid product code.
  var productCode: String? { kind == .product ? LabelCodes.productCode(raw) : nil }
}

enum LabelCodes {
  private static func digits(_ s: String) -> [Int]? {
    var out: [Int] = []
    for c in s {
      guard let v = c.wholeNumberValue, c.isASCII else { return nil }
      out.append(v)
    }
    return out
  }

  /// GS1 check digit (EAN-8, UPC-A, EAN-13, GTIN-14): true if the last digit matches.
  static func checkDigitOk(_ code: String) -> Bool {
    guard [8, 12, 13, 14].contains(code.count), let d = digits(code) else { return false }
    let body = d.dropLast()
    var sum = 0
    // Weights 3,1,3,1... from the rightmost digit of the body.
    for (i, v) in body.reversed().enumerated() { sum += v * (i % 2 == 0 ? 3 : 1) }
    return (10 - sum % 10) % 10 == d.last
  }

  /// The lookup form: UPC-A (12) becomes EAN-13 with a leading 0; UPC-E (8, starts 0/1) as is.
  static func productCode(_ raw: String) -> String? {
    let d = LabelsString.trimmed(raw)
    guard !d.isEmpty, digits(d) != nil else { return nil }
    switch d.count {
    case 13, 8: return checkDigitOk(d) ? d : (d.count == 8 && upcEOk(d) ? d : nil)
    case 12: return checkDigitOk(d) ? "0" + d : nil
    default: return nil
    }
  }

  /// UPC-E check: expand to UPC-A and check that.
  private static func upcEOk(_ d: String) -> Bool {
    let c = Array(d)
    guard c.count == 8, c[0] == "0" || c[0] == "1" else { return false }
    let m = Array(c[1..<7])
    let s = String(c[0])
    func str(_ chars: ArraySlice<Character>) -> String { String(chars) }
    let body: String
    switch m[5] {
    case "0", "1", "2": body = s + str(m[0..<2]) + String(m[5]) + "0000" + str(m[2..<5])
    case "3": body = s + str(m[0..<3]) + "00000" + str(m[3..<5])
    case "4": body = s + str(m[0..<4]) + "00000" + String(m[4])
    default: body = s + str(m[0..<5]) + "0000" + String(m[5])
    }
    return checkDigitOk(body + String(c[7]))
  }

  /// "5012345678900" -> "5 0 1 2 ...": digits said one by one.
  static func spokenDigits(_ raw: String) -> String {
    raw.filter { $0.isLetter || $0.isNumber }.map(String.init).joined(separator: " ")
  }

  private static let url = LabelsRegex("^(?:https?://)?(?:www\\.)?([a-z0-9.-]+\\.[a-z]{2,})(?:[:/?#].*)?$", ignoreCase: true)
  private static let wifiName = LabelsRegex("(?:^|;)S:((?:\\\\.|[^;])*)", ignoreCase: true)

  /// What to say about a QR code's content. Never opens anything.
  static func describeQr(_ raw: String) -> String {
    let v = LabelsString.trimmed(raw)
    let lower = v.lowercased()
    if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("www.") {
      if let m = url.first(in: v) {
        return "This is a QR code. It links to \(m.group(1).lowercased()). I won't open links."
      }
      return "This is a QR code with a web link. I won't open links."
    }
    if lower.hasPrefix("wifi:") {
      let name = wifiName.first(in: String(v.dropFirst(5)))?.group(1)
      return "This is a QR code for a Wi-Fi network" + (name.map { " called \($0.replacingOccurrences(of: "\\", with: ""))" } ?? "") + "."
    }
    if lower.hasPrefix("mailto:") {
      let address = String(v.dropFirst(7)).split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
      return "This is a QR code with an email address: \(address)."
    }
    if lower.hasPrefix("tel:") { return "This is a QR code with a phone number: \(spokenDigits(String(v.dropFirst(4))))." }
    if lower.hasPrefix("begin:vcard") { return "This is a QR code with contact details." }
    if v.isEmpty { return "This is a QR code, but it's empty." }
    var text = v
    if v.count > 200 {
      let head = String(v.prefix(200))
      let cut = head.range(of: " ", options: .backwards).map { String(head[..<$0.lowerBound]) } ?? head
      text = cut + "\u{2026}"
    }
    return "This is a QR code. It says: \(text)"
  }
}
