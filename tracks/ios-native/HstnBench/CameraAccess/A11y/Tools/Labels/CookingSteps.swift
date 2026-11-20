/*
 * CookingSteps - a pack's cooking instructions as steps to step through
 *
 * Roadmap V2 food check: "how do I cook it" reads the cooking instructions one step at a time, with
 * "next step", "previous step" and "repeat step". Steps come from the cooking section (LabelText):
 * method headings ("Oven cook:", "Microwave:", "Hob:") start a group, numbered steps are used when
 * the pack numbers them 1, 2, 3, and otherwise each sentence is a step.
 *
 * Temperatures and times are read exactly as printed. `spoken` only spells symbols out for the
 * voice ("200°C" is "200 degrees Celsius", "20-25 mins" is "20 to 25 minutes", "800W" is "800
 * watts"); it never converts a unit. The screen shows the step as printed.
 */

import Foundation

struct CookingStep: Equatable, Sendable {
  /// "Oven", "Microwave", or nil when the pack names no method.
  var method: String?
  /// As printed.
  var text: String
}

enum CookingSteps {
  private static let whitespace = LabelsRegex("\\s+")
  private static let brokenWord = LabelsRegex("([a-z])- ([a-z])")
  /// The section's own heading at the start ("Cooking instructions:").
  private static let generalHeading = LabelsRegex(
    "^(?:cooking\\s+(?:instructions|guidelines|guide|method)|preparation(?:\\s+guidelines|\\s+instructions)?|how\\s+to\\s+(?:cook|prepare)|"
      + "to\\s+prepare|directions)\\s*[:;.\\-]?\\s*",
    ignoreCase: true)
  /// A method heading followed by a colon or dash: "Oven cook:", "MICROWAVE -", "Air fryer:".
  private static let method = LabelsRegex(
    "(?<![A-Za-z])((?:fan\\s+oven|conventional\\s+oven|electric\\s+oven|gas\\s+oven|oven|microwave|hob|grill|air\\s*fryer|steam|"
      + "pan\\s*fry|shallow\\s*fry|deep\\s*fry|bbq|barbecue)(?:\\s+cook(?:ing)?|\\s+heat(?:ing)?)?(?:\\s+from\\s+(?:frozen|chilled))?|"
      + "from\\s+(?:frozen|chilled))\\s*[:\\-\u{2013}]\\s*",
    ignoreCase: true)
  /// "1.", "2)", "Step 3:" at the start or after a space, before a word.
  private static let number = LabelsRegex("(?:^|(?<=\\s))(?:step\\s*)?(\\d{1,2})\\s*[.):]\\s+(?=[A-Za-z])", ignoreCase: true)
  private static let bullet = LabelsRegex("\\s*[\u{2022}\u{25CF}\u{25AA}\u{2023}]\\s*")
  /// Sentence ends, not after "approx." or "e.g.".
  private static let sentenceBreak = LabelsRegex("(?<!\\bapprox\\.)(?<!\\be\\.g\\.)(?<!\\bi\\.e\\.)(?<=[.!?])\\s+(?=[A-Z0-9(])")

  /// The cooking section's text as steps, in order.
  static func split(_ section: String) -> [CookingStep] {
    var text = LabelsString.trimmed(whitespace.replace(in: section) { _ in " " })
    text = brokenWord.replace(in: text) { "\($0.group(1))\($0.group(2))" }
    text = LabelsString.trimmed(generalHeading.replace(in: text) { _ in "" })
    guard !text.isEmpty else { return [] }

    // Groups by method heading.
    var groups: [(String?, String)] = []
    let heads = method.all(in: text)
    if heads.isEmpty {
      groups = [(nil, text)]
    } else {
      let before = LabelsString.trimmed(LabelsString.substring(text, from: 0, to: heads[0].start))
      if !before.isEmpty { groups.append((nil, before)) }
      for (i, head) in heads.enumerated() {
        let end = i + 1 < heads.count ? heads[i + 1].start : LabelsString.length(text)
        let body = LabelsString.trimmed(LabelsString.substring(text, from: head.end, to: end))
        groups.append((methodName(head.group(1)), body))
      }
    }

    var steps: [CookingStep] = []
    for (name, body) in groups {
      for part in splitBody(body) { steps.append(CookingStep(method: name, text: part)) }
    }
    return steps
  }

  private static let cookWord = LabelsRegex(" (?:cook(?:ing)?|heat(?:ing)?)(?= |$)")

  private static func methodName(_ raw: String) -> String {
    var words = LabelsString.trimmed(whitespace.replace(in: raw.lowercased()) { _ in " " })
    words = cookWord.replace(in: words) { _ in "" }
    guard let first = words.first else { return words }
    return first.uppercased() + words.dropFirst()
  }

  /// One method's text as steps: numbered when numbered 1, 2, 3...; else bullets; else sentences.
  private static func splitBody(_ body: String) -> [String] {
    var parts: [String]
    let numbers = number.all(in: body)
    var chain: [LabelsRegex.Hit] = []
    for hit in numbers where Int(hit.group(1)) == chain.count + 1 { chain.append(hit) }
    if chain.count >= 2 {
      parts = []
      let before = LabelsString.trimmed(LabelsString.substring(body, from: 0, to: chain[0].start))
      if !before.isEmpty { parts.append(before) }
      for (i, hit) in chain.enumerated() {
        let end = i + 1 < chain.count ? chain[i + 1].start : LabelsString.length(body)
        parts.append(LabelsString.substring(body, from: hit.end, to: end))
      }
    } else {
      parts = bullet.replace(in: body) { _ in "\n" }.split(separator: "\n").map(String.init)
      parts = parts.flatMap { sentenceBreak.replace(in: $0) { _ in "\n" }.split(separator: "\n").map(String.init) }
    }
    parts = parts.map { LabelsString.trimmed($0) }.filter { !$0.isEmpty }
    if chain.count >= 2 { return parts }
    // A fragment of one word ("Stir.") joins the step before.
    var merged: [String] = []
    for part in parts {
      if let last = merged.last, part.split(separator: " ").count < 2, part.count < 8 {
        merged[merged.count - 1] = last + " " + part
      } else {
        merged.append(part)
      }
    }
    return merged
  }

  // MARK: Speaking (symbols spelled out, never converted)

  private static let celsius = LabelsRegex("(\\d)\\s*[\u{00B0}\u{00BA}\u{02DA}]\\s*C\\b")
  private static let fahrenheit = LabelsRegex("(\\d)\\s*[\u{00B0}\u{00BA}\u{02DA}]\\s*F\\b")
  private static let degrees = LabelsRegex("(\\d)\\s*[\u{00B0}\u{00BA}\u{02DA}]")
  private static let range = LabelsRegex("(\\d)\\s*[-\u{2013}]\\s*(\\d)")
  private static let watts = LabelsRegex("(\\d)\\s*W\\b")
  private static let minutes = LabelsRegex("(?<![\\d.])(\\d+)\\s*(?:mins?|minutes?)(?![a-z])", ignoreCase: true)
  private static let seconds = LabelsRegex("(?<![\\d.])(\\d+)\\s*(?:secs?|seconds?|s)(?![A-Za-z])")
  private static let hours = LabelsRegex("(?<![\\d.])(\\d+)\\s*(?:hrs?|hours?)(?![a-z])", ignoreCase: true)

  private static func unit(_ number: String, _ name: String) -> String { number == "1" ? "1 \(name)" : "\(number) \(name)s" }
  private static let slash = LabelsRegex("(?<!\\d)\\s*/\\s*|\\s*/\\s*(?!\\d)")

  /// The step for the voice: the same numbers and units as printed, symbols spelled out.
  static func spoken(_ text: String) -> String {
    var t = text
    t = celsius.replace(in: t) { "\($0.group(1)) degrees Celsius" }
    t = fahrenheit.replace(in: t) { "\($0.group(1)) degrees Fahrenheit" }
    t = degrees.replace(in: t) { "\($0.group(1)) degrees" }
    t = range.replace(in: t) { "\($0.group(1)) to \($0.group(2))" }
    t = watts.replace(in: t) { "\($0.group(1)) watts" }
    t = minutes.replace(in: t) { unit($0.group(1), "minute") }
    t = seconds.replace(in: t) { unit($0.group(1), "second") }
    t = hours.replace(in: t) { unit($0.group(1), "hour") }
    t = slash.replace(in: t) { _ in ", or " }
    return LabelsString.trimmed(whitespace.replace(in: t) { _ in " " })
  }

  /// "Step 2 of 5. Oven: Preheat the oven to 200 degrees Celsius." The method is said on the first
  /// step of its group, and whenever `alwaysMethod` (a step repeated or gone back to).
  static func line(_ steps: [CookingStep], _ index: Int, alwaysMethod: Bool = false) -> String {
    guard steps.indices.contains(index) else { return "" }
    let step = steps[index]
    let newMethod = index == 0 || steps[index - 1].method != step.method
    var out = "Step \(index + 1) of \(steps.count). "
    if let method = step.method, newMethod || alwaysMethod { out += "\(method): " }
    out += spoken(step.text)
    if !out.hasSuffix(".") && !out.hasSuffix("!") && !out.hasSuffix("?") { out += "." }
    if index == steps.count - 1, steps.count > 1 { out += " That's the last step." }
    return out
  }

  /// "Cooking instructions, 6 steps: oven and microwave."
  static func intro(_ steps: [CookingStep]) -> String {
    var methods: [String] = []
    for step in steps { if let m = step.method?.lowercased(), !methods.contains(m) { methods.append(m) } }
    let count = steps.count == 1 ? "1 step" : "\(steps.count) steps"
    if methods.isEmpty { return "Cooking instructions, \(count)." }
    return "Cooking instructions, \(count): \(LabelText.listWords(methods))."
  }
}
