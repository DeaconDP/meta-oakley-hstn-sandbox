/*
 * FoodAllergens - the 14 UK/EU major allergens, the words that mean them, and "my allergens"
 *
 * Food check (roadmap V2) compares a pack with the user's own list. The list holds allergens from
 * the 14 the UK and EU require on labels (Food Information Regulation, Annex II), each with the
 * ingredient words that mean it: milk is also whey, casein, lactose, butter, cream, cheese;
 * cereals containing gluten are also wheat, barley, rye, oats, spelt, semolina, malt; and so on.
 * Look-alikes are masked out first ("cocoa butter" isn't milk, "buckwheat" isn't wheat).
 *
 * `MyAllergens` keeps the list on the phone (UserDefaults, nothing leaves it). `resolve` turns what
 * the user said ("peanuts and milk", "dairy", "shellfish") into catalogue entries, with a note when
 * a word covers more or less than people expect: "nuts" means tree nuts on UK labels, so peanuts are
 * offered separately; "shellfish" adds crustaceans and molluscs.
 */

import Foundation
import Observation

struct FoodAllergen: Equatable, Hashable, Sendable, Identifiable {
  /// Stable, for storage.
  var id: String
  /// Said in answers: "Contains milk".
  var spoken: String
  /// On the screen, as the regulation names it.
  var title: String
  /// Ingredient words that mean this allergen. Plurals are matched too ("almonds", "eggs").
  var terms: [String]
  /// Open Food Facts tags for corroboration.
  var tags: [String]
  /// Phrases that contain a term but aren't the allergen.
  var notTerms: [String] = []
  /// What people call it when they set their list ("dairy", "shellfish" is handled separately).
  var names: [String]
}

enum FoodAllergens {
  static let all: [FoodAllergen] = [
    FoodAllergen(
      id: "celery", spoken: "celery", title: "Celery", terms: ["celery", "celeriac"], tags: ["en:celery"], names: ["celery", "celeriac"]),
    FoodAllergen(
      id: "gluten", spoken: "gluten", title: "Cereals containing gluten",
      terms: [
        "gluten", "wheat", "barley", "rye", "oat", "spelt", "kamut", "khorasan", "durum", "semolina", "couscous", "bulgur", "bulgar",
        "freekeh", "farro", "einkorn", "emmer", "triticale", "malt", "malted",
      ],
      tags: ["en:gluten"],
      notTerms: ["buckwheat"],
      names: ["gluten", "cereals containing gluten", "cereals", "wheat", "barley", "rye", "oats", "oat", "spelt", "coeliac"]),
    FoodAllergen(
      id: "crustaceans", spoken: "crustaceans", title: "Crustaceans",
      terms: ["crustacean", "prawn", "shrimp", "crab", "lobster", "crayfish", "langoustine", "scampi", "krill"],
      tags: ["en:crustaceans"], names: ["crustaceans", "crustacean", "prawns", "prawn", "shrimp", "crab", "lobster"]),
    FoodAllergen(
      id: "eggs", spoken: "eggs", title: "Eggs",
      terms: ["egg", "albumen", "albumin", "ovalbumin", "lysozyme", "mayonnaise", "meringue"], tags: ["en:eggs"],
      notTerms: ["eggplant", "egg free", "egg-free"], names: ["eggs", "egg"]),
    FoodAllergen(
      id: "fish", spoken: "fish", title: "Fish",
      terms: [
        "fish", "anchovy", "anchovies", "salmon", "tuna", "cod", "haddock", "pollock", "pollack", "mackerel", "sardine", "trout", "hake",
        "plaice", "pilchard", "herring", "basa", "tilapia", "coley", "whitebait",
      ],
      tags: ["en:fish"], names: ["fish"]),
    FoodAllergen(id: "lupin", spoken: "lupin", title: "Lupin", terms: ["lupin", "lupine"], tags: ["en:lupin"], names: ["lupin", "lupine"]),
    FoodAllergen(
      id: "milk", spoken: "milk", title: "Milk",
      terms: [
        "milk", "whey", "casein", "caseinate", "lactose", "cream", "butter", "buttermilk", "cheese", "yoghurt", "yogurt", "ghee", "curd",
        "lactalbumin", "lactoglobulin", "dairy", "fromage frais", "creme fraiche", "quark",
      ],
      tags: ["en:milk"],
      notTerms: [
        "cocoa butter", "peanut butter", "shea butter", "nut butter", "almond butter", "cashew butter", "coconut milk", "coconut cream",
        "cream of tartar", "almond milk", "oat milk", "soya milk", "soy milk", "rice milk", "milk thistle", "cream crackers",
        "dairy free", "dairy-free", "milk free", "milk-free", "non-dairy", "non dairy",
      ],
      names: ["milk", "dairy", "lactose", "cows milk", "milk products"]),
    FoodAllergen(
      id: "molluscs", spoken: "molluscs", title: "Molluscs",
      terms: [
        "mollusc", "mollusk", "squid", "octopus", "mussel", "oyster", "clam", "scallop", "snail", "whelk", "cockle", "cuttlefish",
        "calamari", "winkle", "abalone",
      ],
      tags: ["en:molluscs"], notTerms: ["oyster mushroom"], names: ["molluscs", "mollusc", "mussels", "squid", "oysters", "clams"]),
    FoodAllergen(id: "mustard", spoken: "mustard", title: "Mustard", terms: ["mustard"], tags: ["en:mustard"], names: ["mustard"]),
    FoodAllergen(
      id: "peanuts", spoken: "peanuts", title: "Peanuts", terms: ["peanut", "groundnut", "arachis", "monkey nut"], tags: ["en:peanuts"],
      names: ["peanuts", "peanut", "groundnuts", "groundnut"]),
    FoodAllergen(
      id: "sesame", spoken: "sesame", title: "Sesame", terms: ["sesame", "tahini", "tahina", "gingelly", "benne seed"],
      tags: ["en:sesame-seeds"], names: ["sesame", "sesame seeds", "sesame seed", "tahini"]),
    FoodAllergen(
      id: "soya", spoken: "soya", title: "Soya", terms: ["soya", "soy", "soybean", "soyabean", "edamame", "tofu", "miso", "tempeh"],
      tags: ["en:soybeans"], names: ["soya", "soy", "soybeans", "soya beans", "soybean"]),
    FoodAllergen(
      id: "sulphites", spoken: "sulphites", title: "Sulphur dioxide and sulphites",
      terms: [
        "sulphite", "sulfite", "sulphur dioxide", "sulfur dioxide", "metabisulphite", "metabisulfite", "bisulphite", "bisulfite",
        "e220", "e221", "e222", "e223", "e224", "e225", "e226", "e227", "e228",
      ],
      tags: ["en:sulphur-dioxide-and-sulphites"], names: ["sulphites", "sulfites", "sulphite", "sulfite", "sulphur dioxide", "sulfur dioxide"]),
    FoodAllergen(
      id: "treenuts", spoken: "tree nuts", title: "Tree nuts",
      terms: [
        "nut", "almond", "hazelnut", "walnut", "cashew", "pecan", "pistachio", "macadamia", "brazil nut", "queensland nut", "filbert",
        "praline", "marzipan",
      ],
      tags: ["en:nuts"],
      notTerms: ["nutmeg", "coconut", "butternut", "doughnut", "donut", "monkey nut", "nut free", "nut-free", "tiger nut", "pine nut"],
      names: ["tree nuts", "tree nut", "almonds", "hazelnuts", "walnuts", "cashews", "pecans", "pistachios"]),
  ]

  static func allergen(id: String) -> FoodAllergen? { all.first { $0.id == id } }

  /// What resolving a spoken list found.
  struct Resolved: Equatable, Sendable {
    var allergens: [FoodAllergen] = []
    /// Words that aren't one of the 14.
    var unknown: [String] = []
    /// Said after the change: "nuts" is tree nuts, "shellfish" is two allergens.
    var notes: [String] = []
  }

  /// Words between allergens that carry nothing.
  private static let glue: Set<String> = [
    "and", "or", "also", "too", "the", "my", "to", "from", "list", "allergens", "allergies", "allergy", "allergen", "a", "an", "of",
    "plus", "as", "well", "with", "any", "all", "are", "is", "it", "them", "that", "this", "on", "off", "please",
  ]

  /// "peanuts and milk", "dairy, sesame seeds", "nuts": catalogue entries in the order said.
  static func resolve(_ phrase: String) -> Resolved {
    let words = LabelsPhrases.normalize(phrase).split(separator: " ").map(String.init)
    var out = Resolved()
    func add(_ a: FoodAllergen) { if !out.allergens.contains(a) { out.allergens.append(a) } }
    var i = 0
    while i < words.count {
      var matched = false
      for length in stride(from: min(4, words.count - i), through: 1, by: -1) {
        let candidate = words[i..<(i + length)].joined(separator: " ")
        if candidate == "nuts" || candidate == "nut" {
          add(allergen(id: "treenuts")!)
          out.notes.append("On UK labels, nuts means tree nuts, so I added tree nuts. Peanuts are separate: say add peanuts if you need them.")
        } else if candidate == "shellfish" || candidate == "seafood" {
          add(allergen(id: "crustaceans")!)
          add(allergen(id: "molluscs")!)
          out.notes.append("Shellfish covers crustaceans and molluscs, so I added both.")
        } else if let a = all.first(where: { $0.names.contains(candidate) || $0.spoken == candidate || $0.title.lowercased() == candidate }) {
          add(a)
        } else {
          continue
        }
        i += length
        matched = true
        break
      }
      if !matched {
        if !glue.contains(words[i]) { out.unknown.append(words[i]) }
        i += 1
      }
    }
    return out
  }

  /// "peanuts, milk and sesame".
  static func spokenList(_ allergens: [FoodAllergen]) -> String { LabelText.listWords(allergens.map(\.spoken)) }

  /// Every name, for "I check for ...".
  static var catalogueSpoken: String { spokenList(all) }
}

/// The user's allergens, kept on the phone. Shared so the panel and voice see the same list.
@MainActor
@Observable
final class MyAllergens {
  static let shared = MyAllergens()
  static let storageKey = "labels.myAllergens"

  @ObservationIgnored private let defaults: UserDefaults
  /// In catalogue order.
  private(set) var allergens: [FoodAllergen]

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let ids = defaults.stringArray(forKey: Self.storageKey) ?? []
    allergens = FoodAllergens.all.filter { ids.contains($0.id) }
  }

  var isEmpty: Bool { allergens.isEmpty }

  func contains(_ allergen: FoodAllergen) -> Bool { allergens.contains(allergen) }

  /// Replaces the list.
  func set(_ list: [FoodAllergen]) {
    allergens = FoodAllergens.all.filter { list.contains($0) }
    save()
  }

  /// Adds; returns the ones that weren't there.
  @discardableResult
  func add(_ list: [FoodAllergen]) -> [FoodAllergen] {
    let new = list.filter { !allergens.contains($0) }
    set(allergens + new)
    return new
  }

  /// Removes; returns the ones that were there.
  @discardableResult
  func remove(_ list: [FoodAllergen]) -> [FoodAllergen] {
    let gone = list.filter { allergens.contains($0) }
    set(allergens.filter { !list.contains($0) })
    return gone
  }

  private func save() {
    defaults.set(allergens.map(\.id), forKey: Self.storageKey)
  }
}
