/*
 * OpenFoodFacts - the product lookup, its reply, and what is said about the product
 *
 * Port of Android's tools/labels/OpenFoodFacts.kt. The label reader's only network call, made only
 * when the user says "look it up" (or taps Look it up) after a barcode decoded. Only the barcode
 * number is sent (GET /api/v2/product/<code>.json with the fields we speak, no key, a descriptive
 * User-Agent as Open Food Facts asks, an ephemeral session so no cookies or cache); never an image,
 * any label text, or anything about the user. Found products are cached on the phone (one JSON file
 * per barcode in Caches), so asking again works offline.
 *
 * `OpenFoodFacts.parse` turns the reply into an OffProduct. `ProductSource` is the seam tests replace
 * with a fake (LabelsTool's init takes one).
 */

import Foundation

/// A product as Open Food Facts describes it. Lists hold tags such as "en:milk".
struct OffProduct: Equatable, Sendable {
  var code: String
  var name: String?
  var brands: [String]
  var quantity: String?
  var allergenTags: [String]
  var traceTags: [String]
  var ingredients: String?
  var categoryTags: [String]

  /// Brands without the product's own name ("Nutella, Ferrero" for Nutella gives "Ferrero").
  var otherBrands: [String] { brands.filter { brand in name.map { brand.caseInsensitiveCompare($0) != .orderedSame } ?? true } }

  var allergens: [String] { Self.unique(allergenTags.map(OpenFoodFacts.tagName)) }
  var traces: [String] { Self.unique(traceTags.map(OpenFoodFacts.tagName)) }

  /// "Snickers, by Mars Wrigley Confectionery UK Limited, 50 grams."
  func summary() -> String {
    var parts = [name ?? "A product with no name recorded"]
    if let brand = otherBrands.first { parts.append("by \(brand)") }
    if let quantity {
      let spoken = OpenFoodFacts.spokenQuantity(quantity)
      if !spoken.isEmpty { parts.append(spoken) }
    }
    return parts.joined(separator: ", ") + "."
  }

  private static func unique(_ list: [String]) -> [String] {
    var seen = Set<String>()
    return list.filter { seen.insert($0).inserted }
  }
}

enum ProductLookupResult: Equatable, Sendable {
  case found(OffProduct, fromCache: Bool)
  /// Open Food Facts doesn't know this barcode.
  case notFound
  /// No network.
  case offline
  case failed(String)
}

/// Where products come from. Tests inject a fake.
protocol ProductSource: Sendable {
  func lookup(_ code: String) async -> ProductLookupResult
}

enum OpenFoodFacts {
  static let userAgent = "SpeakUp-LabelReader/0.1 (iOS; accessibility app for blind users; barcode lookups only)"

  /// Only the fields the label reader speaks, to keep the reply small.
  private static let fields =
    "code,product_name,product_name_en,brands,quantity,allergens_tags,traces_tags,"
    + "ingredients_text,ingredients_text_en,categories_tags"

  /// The request URL. It holds the barcode number and nothing else that varies.
  static func url(_ code: String) -> URL? {
    URL(string: "https://world.openfoodfacts.org/api/v2/product/\(code).json?fields=\(fields)")
  }

  enum ParseError: Error { case notJSON }

  /// A reply body to found or notFound. Throws if it isn't a JSON object.
  static func parse(_ data: Data, requestedCode: String? = nil) throws -> ProductLookupResult {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ParseError.notJSON }
    let status = (root["status"] as? NSNumber)?.intValue ?? 0
    guard status == 1, let product = root["product"] as? [String: Any] else { return .notFound }
    func text(_ key: String) -> String? {
      guard let value = product[key] as? String else { return nil }
      let trimmed = LabelsString.trimmed(value)
      return trimmed.isEmpty ? nil : trimmed
    }
    func tags(_ key: String) -> [String] { (product[key] as? [Any])?.compactMap { $0 as? String } ?? [] }
    var brands: [String] = []
    for brand in (text("brands") ?? "").split(separator: ",").map({ LabelsString.trimmed(String($0)) }) where !brand.isEmpty {
      if !brands.contains(where: { $0.lowercased() == brand.lowercased() }) { brands.append(brand) }
    }
    return .found(
      OffProduct(
        code: (root["code"] as? String) ?? requestedCode ?? "",
        name: text("product_name_en") ?? text("product_name"),
        brands: brands,
        quantity: text("quantity"),
        allergenTags: tags("allergens_tags"),
        traceTags: tags("traces_tags"),
        ingredients: text("ingredients_text_en") ?? text("ingredients_text"),
        categoryTags: tags("categories_tags")),
      fromCache: false)
  }

  private static let tagNames = [
    "milk": "milk", "nuts": "nuts", "peanuts": "peanuts", "soybeans": "soya", "gluten": "gluten", "eggs": "eggs", "fish": "fish",
    "crustaceans": "crustaceans", "molluscs": "molluscs", "sesame-seeds": "sesame", "mustard": "mustard", "celery": "celery",
    "lupin": "lupin", "sulphur-dioxide-and-sulphites": "sulphites",
  ]

  /// "en:soybeans" -> "soya", "fr:fruits-a-coque" -> "fruits a coque".
  static func tagName(_ tag: String) -> String {
    let bare = tag.split(separator: ":", maxSplits: 1).last.map(String.init) ?? tag
    return tagNames[bare.lowercased()] ?? bare.replacingOccurrences(of: "-", with: " ").lowercased()
  }

  private static let units = [
    "g": "grams", "gr": "grams", "kg": "kilograms", "mg": "milligrams", "ml": "millilitres", "cl": "centilitres", "l": "litres",
    "oz": "ounces", "lb": "pounds", "fl oz": "fluid ounces",
  ]
  private static let unitPattern = LabelsRegex("(\\d)\\s*(fl oz|kg|mg|ml|cl|gr|oz|lb|g|l)\\b", ignoreCase: true)
  private static let trailingE = LabelsRegex("\\s+e$")
  private static let spaces = LabelsRegex("\\s+")

  /// "400 g e" -> "400 grams", "50 G" -> "50 grams", "6 x 330ml" -> "6 x 330 millilitres".
  static func spokenQuantity(_ raw: String) -> String {
    var q = LabelsString.trimmed(raw).replacingOccurrences(of: "\u{212E}", with: " ")
    q = LabelsString.trimmed(trailingE.replace(in: q) { _ in "" })
    q = unitPattern.replace(in: q) { m in "\(m.group(1)) \(units[m.group(2).lowercased()] ?? m.group(2))" }
    return LabelsString.trimmed(spaces.replace(in: q) { _ in " " })
  }
}

/// The real lookup: the on-phone cache first, then Open Food Facts over HTTPS.
struct OpenFoodFactsSource: ProductSource {
  typealias Fetch = @Sendable (URL) async throws -> (status: Int, body: Data)

  let cacheDirectory: URL
  let fetch: Fetch

  init(cacheDirectory: URL = OpenFoodFactsSource.defaultCacheDirectory, fetch: @escaping Fetch = OpenFoodFactsSource.httpGet) {
    self.cacheDirectory = cacheDirectory
    self.fetch = fetch
  }

  static var defaultCacheDirectory: URL {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
    return caches.appendingPathComponent("labels_products", isDirectory: true)
  }

  func lookup(_ code: String) async -> ProductLookupResult {
    guard !code.isEmpty, code.allSatisfy({ $0.isASCII && $0.isNumber }), let url = OpenFoodFacts.url(code) else {
      return .failed("Barcode must be digits")
    }
    let cached = cacheDirectory.appendingPathComponent("\(code).json")
    if let data = try? Data(contentsOf: cached), case .found(let product, _)? = try? OpenFoodFacts.parse(data, requestedCode: code) {
      return .found(product, fromCache: true)
    }
    do {
      let (status, body) = try await fetch(url)
      // A product Open Food Facts doesn't know comes back as 404 with status 0.
      guard status == 200 || status == 404 else { return .failed("HTTP \(status)") }
      let result = try OpenFoodFacts.parse(body, requestedCode: code)
      if case .found = result {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? body.write(to: cached, options: .atomic)
      }
      return result
    } catch let error as URLError {
      switch error.code {
      case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .timedOut, .networkConnectionLost, .dnsLookupFailed,
        .dataNotAllowed, .internationalRoamingOff:
        return .offline
      default:
        return .failed(error.localizedDescription)
      }
    } catch is OpenFoodFacts.ParseError {
      return .failed("unreadable reply")
    } catch {
      return .failed(error.localizedDescription)
    }
  }

  /// An ephemeral session: no cookies, no shared URL cache, nothing about the user.
  static let httpGet: Fetch = { url in
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 10
    configuration.httpAdditionalHeaders = ["User-Agent": OpenFoodFacts.userAgent, "Accept": "application/json"]
    let session = URLSession(configuration: configuration)
    defer { session.finishTasksAndInvalidate() }
    let (data, response) = try await session.data(from: url)
    return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
  }
}
