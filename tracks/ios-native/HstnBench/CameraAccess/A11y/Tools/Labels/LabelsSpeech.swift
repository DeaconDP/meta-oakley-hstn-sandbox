/*
 * LabelsSpeech - the label reader's spoken lines, in one place
 *
 * Android's res/values/strings_labels.xml, worded for the phone first: "hold it in front of the
 * camera", "a hand's length from the phone". Rules as in SpokenMessage: lead with what happened,
 * then one next step; the last words are what to say next.
 */

enum LabelsSpeech {
  static let help =
    "Hold up a packet, tin or box in front of the camera. You can say: scan this, look it up, read the label, read it all, when does it expire, "
    + "ingredients, how do I cook it, then next step, allergens, does it contain nuts, what is it, or stop scanning. "
    + "For food check, tell me your allergens, for example my allergens are peanuts and milk, then say is this OK for me. "
    + "Only the barcode number goes online, and only when you say look it up."

  // Food check: my allergens
  static let noAllergensSet =
    "You haven't told me your allergens yet. Say, for example, my allergens are peanuts and milk. Then say is this OK for me."
  static func myAllergens(_ list: String) -> String { "Your allergens are \(list)." }
  static func notRecognised(_ words: [String]) -> String {
    "I didn't recognise \(LabelText.listWords(words)). I check the 14 main allergens: \(FoodAllergens.catalogueSpoken)."
  }
  static let noAllergenHeard = "I didn't catch an allergen. Say, for example, add sesame."
  static let allergensCleared = "I've cleared your allergens."
  static let listEmpty = "Your list is now empty."
  static func added(_ list: String) -> String { "Added \(list)." }
  static func alreadyOn(_ list: String) -> String { "Already on your list: \(list)." }
  static func removed(_ list: String) -> String { "Removed \(list)." }
  static func notOn(_ list: String) -> String { "Not on your list: \(list)." }
  static let foodCheckAfterSet = "Say is this OK for me with a pack in view."

  // Cooking steps
  static let stepsHow = "Say next step, previous step or repeat step."
  static let noSteps = "I haven't read any cooking steps yet. Say how do I cook it."
  static let lastStepAlready = "That was the last step. Say repeat step, or previous step."
  static let firstStepAlready = "This is the first step. Say next step to go on."

  // Reminders
  static let noDateForReminder = "I need a clear use by or best before date first. Say when does it expire."
  static let reminderPassed = "That date has already passed, so there's nothing to remind you about."
  static let reminderTooSoon = "It goes off today, so it's too late for a reminder."

  // Searching
  static let searching = "Looking for a barcode. Hold it in front of the camera and turn it slowly."
  static let turnHint = "Turn it slowly. Barcodes are usually on the back or bottom."
  static let barsCloser = "I can see a barcode. Bring it a little closer and hold it steady."
  static let barsSteady = "I can see a barcode. Hold it steady."
  static let noBarcode = "I couldn't find a barcode. I'll read the label instead."
  static let foundProduct = "Found a barcode. Say look it up to get the product name, or read the label."
  static func foundOther(_ digits: String) -> String {
    "Found a barcode, but it isn't a product barcode. It reads \(digits). Say read the label to hear the text."
  }
  static let qrMore = "Say read the label to hear the text around it."
  static let stopped = "Stopped. Say scan this to look again."

  // Lookup
  static let noCodeYet = "I haven't found a barcode yet. Say scan this to look for one, or read the label."
  static let stillSearching = "I'm still looking for a barcode. Turn it slowly, or say read the label."
  static let notProduct = "That isn't a product barcode, so I can't look it up. Say read the label."
  static let lookingUp = "Looking it up on Open Food Facts. Only the barcode number is sent."
  static let lookupMore = "Say allergens or ingredients for more, or read the label."
  static let notFound = "Open Food Facts doesn't know this product. Say read the label, and I'll read it to you."
  static let offline = "I can't reach the internet, so I can't look it up. Say read the label, and I'll read it to you."
  static let lookupFailed = "The product lookup didn't work just now. Say look it up to try again, or read the label."
  static func ingredientsFromOff(_ text: String) -> String { "From Open Food Facts, the ingredients are: \(text)" }

  // Reading
  static let reading = "Reading the label."
  static let captureFailed = "I couldn't get a picture from the camera. Say read the label to try again."
  static func noText(_ camera: CameraKind) -> String {
    camera == .phone
      ? "I can't read any writing. Hold it about a hand's length from the phone, keep it steady, and say read the label again."
      : "I can't read any writing. Hold it about a hand's length from your face, keep it steady, and say read the label again."
  }
  static let textSmall = "The writing is too small. Bring it closer and say read the label again."
  static let blurred = "The picture is blurred. Hold it still and say read the label again."
  static func tooDark(_ camera: CameraKind) -> String {
    camera == .phone
      ? "It's too dark to read. Say torch on, or turn on a light, then say read the label."
      : "It's too dark to read. Turn on a light, then say read the label."
  }
  static let ocrFailed = "Sorry, reading the label failed. Say read the label to try again."
  static let readMore = "That's all I can see. You can ask when does it expire, ingredients, allergens or cooking instructions."
  static let noExpiry = "I can't find a date on this side. Dates are often on the top, the bottom or the back. Turn it and ask again."
  static let noIngredients = "I can't find the ingredients on this side. Turn it slowly and ask again."
  static let noCooking = "I can't find cooking instructions on this side. Turn it slowly and ask again."
  static let noAllergens = "I can't find allergy information on this side. Turn it and ask again, or say ingredients."
  static let noName = "I don't know what it is yet. Say scan this, or read the label."
  static func nameLabel(_ name: String) -> String { "The biggest writing says: \(name)." }

  // Medicine: the name only, never doses (ROADMAP ground rule).
  static func medicineName(_ name: String) -> String { "This looks like medicine: \(name)." }
  static let medicineOnlyName = "For medicine I only tell you the name and the date."
  static let medicineDose = "I won't read medicine doses. Please check with a pharmacist or a trusted person."
  static func medicineScreen(_ name: String) -> String { "Medicine: \(name). Only the name is shown. Doses are not read." }
}
