# Food check (iOS)

2026-11-20. Roadmap V2 "food check", built inside the Labels and barcodes tool. It has three parts: your allergens, the date against today, and cooking steps.

Code: `tracks/ios-native/HstnBench/CameraAccess/A11y/Tools/Labels/`
- `FoodAllergens.swift`: the 14 allergens, the words for each, and `MyAllergens`, the saved list.
- `FoodCheck.swift`: "Is this OK for me?"
- `FoodDates.swift`: the date against today, and the reminder request.
- `CookingSteps.swift`: cooking instructions split into steps.
- `LabelsTool.swift`, `LabelsGrammar.swift`, `LabelsSpeech.swift`, `LabelsPanel.swift`: the wiring.
- `LabelText.swift`: a new `sectionLines` says how a section ended. `LabelLine` has a new `touchesEdge` flag.

Tests: `CameraAccessTests/FoodCheckTests.swift`.

**Not tried on a real iPhone or on real packs.** All of this is pure logic, tested with typed-in OCR lines.

## My allergens

- The list uses the 14 UK/EU major allergens: celery, cereals containing gluten, crustaceans, eggs, fish, lupin, milk, molluscs, mustard, tree nuts, peanuts, sesame, soya, sulphites.
- Each allergen has the ingredient words that mean it. Milk also matches whey, casein, caseinate, lactose, butter, cream, cheese, yoghurt and ghee. Gluten also matches wheat, barley, rye, oats, spelt, kamut, semolina, couscous, bulgur and malt.
- Look-alikes are skipped: cocoa butter, coconut milk, cream of tartar, buckwheat, nutmeg, coconut, butternut, oyster mushroom.
- "Nuts" adds tree nuts. It then says that peanuts are separate. "Shellfish" adds crustaceans and molluscs, and says so.
- The list is saved on the phone in UserDefaults (`labels.myAllergens`). It never leaves the phone.

| Say | Does |
|---|---|
| "my allergens are peanuts and milk", "I'm allergic to ..." | Replaces the list |
| "add sesame", "I'm also allergic to sesame" | Adds to the list |
| "remove milk", "I'm not allergic to milk" | Removes from the list |
| "what are my allergens", "what am I allergic to" | Reads the list |
| "clear my allergens" | Empties the list |

A word it doesn't know ("kiwi") is said back, with the 14 it does know.

The panel has a Food check card. It shows your list and has a "Change my allergens" button, which opens a switch for each of the 14.

## Is this OK for me?

Say "is this OK for me", "food check", "can I eat this" or "does it contain my allergens", or tap "Is this OK for me?".

- It takes a fresh photo and looks at every side read so far.
- It finds the ingredients (the "Ingredients" heading must be there) and the allergy advice. A "Contains: milk, soya" line counts as allergy advice.
- It names what it found and where. For example: "Contains milk: it says whey powder in the ingredients."
- "May contain", "traces of" and "made in a factory that handles" are warnings, not "contains". For example: "May contain sesame and tree nuts: the pack says, made in a factory that also handles sesame and nuts."
- "Free from milk" and "dairy free" are not counted as milk.
- "For allergens, see ingredients in bold" is about layout. It is ignored.
- If the list is complete and nothing is found, it says: "I didn't find your allergens in the ingredients I could read. Check the pack if you're unsure."
- It never says "safe" or "allergen free". A test checks every answer for this.

### When it stops short (abstains)

It won't say "not found" when the read is partial. A read is partial when:
- there's no "Ingredients" heading on any side read;
- a line of the list runs into the edge of the photo;
- a line was read with confidence below 0.5;
- the list stops mid-way: it ends with a comma, "and" or an open bracket, or it runs to the last line without a full stop.

Then it says why and asks for a better picture: "The ingredients look cut off, so I can't check them. Move the pack so all the ingredients are in view, hold it steady, and say food check again."

Anything it did find is still named, followed by "so there may be more".

### Open Food Facts

Open Food Facts data is used only if you already said "look it up". It is never fetched for food check.
- If it agrees: "Open Food Facts lists milk too."
- If the pack shows an allergen that Open Food Facts doesn't list: "... but the pack wins: go by the pack."
- If Open Food Facts lists an allergen the pack doesn't show, it is never reported as "contains". It says: "Open Food Facts lists sesame, but I didn't find it on the pack. The pack wins, but check the pack carefully, or ask someone."
- Open Food Facts never fills in a partial read.

Earcons: attention when something is found, done when a complete list has nothing, uncertain (and an error haptic) when it abstains.

## Dates against today

"When does it expire" on food now says how far the date is from today, and what the date means:
- "Use by 21 November: that's tomorrow. Use by is about safety: don't eat it after that date."
- "Use by 20 November: that's today. Use by is about safety: eat it, cook it or freeze it by the end of today."
- "Best before 1 November: that was about 3 weeks ago. Best before is about quality, not safety, so it may just be past its best."
- Display until and sell by: "That date is for the shop. Look for a use by or best before date."

Use by comes first, then best before. The year is said only when it isn't this year.

It stops short when the date isn't fully read:
- a keyword with no date;
- a date line read with confidence below 0.5;
- a date line that runs off the edge of the photo.

Then it says it can't read the date clearly and asks you to move the pack.

Medicine dates are unchanged. They still use `MedicineCheck`, with the pharmacist line.

### Remind me before it goes off

- The offer is made only if `Reminders.shared` is a real reminders feature (not `NoReminders`). The panel shows a "Remind me before it goes off" button only then.
- The reminder fires at 9 am the day before the date. If that time has passed, it fires at 9 am on the day. If the date is today and 9 am has passed, it says it's too late.
- The request id is stable per product and date (`labels.food.<barcode or name>.<date>.<kind>`), so asking twice replaces the first reminder.
- Each result is spoken: scheduled, notifications off, too soon, or "Reminders aren't available in this version yet".
- Medicine labels never get this.

## Cooking steps

Say "how do I cook it", or tap "Cooking steps".

- It finds the cooking section and splits it into steps.
- Method headings ("Oven cook:", "Microwave:", "Hob:", "Air fryer:") start a new group.
- Numbered steps (1, 2, 3) are kept. Otherwise each sentence is a step.
- It says the number of steps and the methods, then step 1. For example: "Step 1 of 6. Oven: Preheat oven to 200 degrees Celsius, or Fan 180 degrees Celsius, or Gas Mark 6."
- Say "next step", "previous step" or "repeat step". While stepping, "next", "back" and "repeat" also work. The panel shows the step as printed, with Previous, Repeat and Next buttons.
- Temperatures and times are read exactly as printed. Only the symbols are said as words: °C is "degrees Celsius", 800W is "800 watts", 20-25 mins is "20 to 25 minutes". Nothing is converted.

## Guardrails

- Every action plays an earcon. Every failure is spoken.
- Nothing goes online except the Open Food Facts lookup you ask for.
- Medicine labels are unchanged. Food check, cooking steps and reminders all give the medicine name and the usual refusal.

## Tests

Mac, Xcode, iOS 27.0 Simulator "SpeakUp Food iPhone 17", `-parallel-testing-enabled NO`. CameraAccess and SpeakUp both build.

- Unit tests, skipping `DATGlassesDisplayMockTests.testTheCardRendersOnTheMockDisplay`: 581 run, 0 failures.
- New in `FoodCheckTests.swift` (52):
  - `FoodAllergenTests`: the 14, spoken lists, ingredient words, look-alikes, peanuts vs tree nuts, may contain, factory lines, "Contains:" lines, bold boilerplate, free-from;
  - `FoodCheckPartialReadTests`: complete list, cut off, no full stop, open bracket, edge, blurred, no heading, found-but-partial;
  - `FoodCheckOpenFoodFactsTests`: agreement, and the pack wins both ways;
  - `FoodDatesTests`: fixed today of 20 November 2026; tomorrow, today, passed, best before, display until, abstaining, reminder times;
  - `CookingStepsTests`: methods, numbered steps, symbols said without converting;
  - `FoodCheckGrammarTests`;
  - `FoodCheckToolTests`: the tool end to end with a fake reminders feature, and medicine unchanged.
- In `LabelsToolTests`, food dates now use the new wording. A new test checks that an unclear food date isn't said.

## Changed behaviour

- A food date is no longer said when its line was read with low confidence. Before, only medicine dates had this rule.
- The cooking instructions button and "cooking instructions" now step through the steps. Before, they read the whole section at once.

## Not tried / limits

- Not tried on real packs. OCR of small ingredient print, and whether "touches the edge" fires too often, are both unknown.
- Allergen words are English only. Bold print isn't visible to OCR, so it can't use bold as a clue.
- A list that ends without a full stop, at the last line of the photo, is treated as cut off. Some packs leave the full stop off, so those will ask for another picture.
- No settings row for the list outside the Labels panel.
