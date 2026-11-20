/*
 * LabelsPanel - the label reader on the phone screen
 *
 * Mirrors the state for low-vision users, sighted helpers and VoiceOver: what the tool is doing, the
 * barcode, the product, the label text (large print), and a medicine banner. For medicine no label
 * text is shown at all, so VoiceOver can't read a dose either. Big buttons do exactly what the
 * voice commands do: Scan, Look it up, Read label, Date, Ingredients, Allergens. Dynamic Type
 * throughout, 60 pt targets (ChunkyButtonStyle), the theme's colours.
 */

import SwiftUI

struct LabelsPanel: View {
  let tool: LabelsTool

  private var phaseText: String {
    switch tool.phase {
    case .idle: "Ready. Say scan this."
    case .searching: "Looking for a barcode"
    case .found: "Barcode found"
    case .lookingUp: "Looking up the product"
    case .reading: "Reading the label"
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(phaseText)
        .font(.rounded(.title, weight: .heavy))
        .foregroundStyle(Theme.ink)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("labels_phase")

      if tool.isMedicine {
        medicineBanner
      }

      if tool.code != nil || tool.productSummary != nil {
        VStack(alignment: .leading, spacing: 8) {
          if let code = tool.code {
            Text("\(code.format) barcode: \(code.kind == .qr ? "QR code" : code.raw)")
              .font(.rounded(.headline, weight: .bold))
              .foregroundStyle(Theme.inkSoft)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("labels_code")
          }
          if let product = tool.productSummary {
            Text(product)
              .font(.rounded(.title2, weight: .heavy))
              .foregroundStyle(Theme.ink)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("labels_product")
          }
        }
        .themeCard()
        .accessibilityElement(children: .combine)
      }

      if !tool.lastLine.isEmpty {
        A11yNote(text: tool.lastLine)
          .accessibilityIdentifier("labels_last_line")
      }

      buttons

      if let index = tool.stepIndex, tool.cookingSteps.indices.contains(index), !tool.isMedicine {
        stepCard(index)
      }

      if !tool.isMedicine {
        FoodCheckCard(tool: tool, allergens: tool.myAllergens)
      }

      if let text = tool.labelText, !tool.isMedicine {
        VStack(alignment: .leading, spacing: 8) {
          Text("Label text")
            .font(.rounded(.headline, weight: .heavy))
            .foregroundStyle(Theme.inkSoft)
            .accessibilityAddTraits(.isHeader)
          Text(text)
            .font(.rounded(.title3, weight: .medium))
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .accessibilityIdentifier("labels_text")
        }
        .themeCard()
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
  }

  private var medicineBanner: some View {
    Label(LabelsSpeech.medicineScreen(tool.medicineName ?? "a medicine"), systemImage: "pills")
      .font(.rounded(.title3, weight: .heavy))
      .foregroundStyle(Theme.onFace(.orange))
      .fixedSize(horizontal: false, vertical: true)
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Theme.face(.orange), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.lip(.orange), lineWidth: 3)
      }
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("labels_medicine")
  }

  @ViewBuilder
  private var buttons: some View {
    Button(tool.phase == .searching ? "Stop scanning" : "Scan") {
      tool.perform(tool.phase == .searching ? .stopScan : .scan)
    }
    .buttonStyle(.a11yPrimary)
    .accessibilityIdentifier("labels_scan")

    Button("Look it up") { tool.perform(.lookUp) }
      .buttonStyle(.a11ySecondary)
      .disabled(tool.code?.productCode == nil || tool.phase == .lookingUp)
      .accessibilityHint("Sends only the barcode number to Open Food Facts.")
      .accessibilityIdentifier("labels_lookup")

    Button("Read label") { tool.perform(.readLabel) }
      .buttonStyle(.a11ySecondary)
      .accessibilityIdentifier("labels_read")

    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) { quickJumps }
      VStack(spacing: 12) { quickJumps }
    }
  }

  /// The cooking step being read, as printed, with Previous, Repeat and Next.
  private func stepCard(_ index: Int) -> some View {
    let step = tool.cookingSteps[index]
    return VStack(alignment: .leading, spacing: 12) {
      Text("Step \(index + 1) of \(tool.cookingSteps.count)\(step.method.map { ", \($0)" } ?? "")")
        .font(.rounded(.headline, weight: .heavy))
        .foregroundStyle(Theme.inkSoft)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("labels_step_title")
      Text(step.text)
        .font(.rounded(.title2, weight: .bold))
        .foregroundStyle(Theme.ink)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("labels_step_text")
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) { stepButtons(index) }
        VStack(spacing: 12) { stepButtons(index) }
      }
    }
    .themeCard()
  }

  @ViewBuilder
  private func stepButtons(_ index: Int) -> some View {
    Button("Previous") { tool.perform(.previousStep) }
      .buttonStyle(.a11ySecondary)
      .disabled(index == 0)
      .accessibilityLabel("Previous step")
      .accessibilityIdentifier("labels_step_previous")
    Button("Repeat") { tool.perform(.repeatStep) }
      .buttonStyle(.a11ySecondary)
      .accessibilityLabel("Repeat step")
      .accessibilityIdentifier("labels_step_repeat")
    Button("Next") { tool.perform(.nextStep) }
      .buttonStyle(.a11ySecondary)
      .disabled(index + 1 >= tool.cookingSteps.count)
      .accessibilityLabel("Next step")
      .accessibilityIdentifier("labels_step_next")
  }

  @ViewBuilder
  private var quickJumps: some View {
    Button("Date") { tool.perform(.expiry) }
      .buttonStyle(.a11ySecondary)
      .accessibilityLabel("Expiry date")
      .accessibilityIdentifier("labels_date")
    Button("Ingredients") { tool.perform(.ingredients) }
      .buttonStyle(.a11ySecondary)
      .accessibilityIdentifier("labels_ingredients")
    Button("Allergens") { tool.perform(.allergens(nil)) }
      .buttonStyle(.a11ySecondary)
      .accessibilityIdentifier("labels_allergens")
  }
}

/// Food check: my allergens (with a switch for each of the 14), "Is this OK for me?", cooking steps,
/// and the reminder when a reminders feature is there. Every button does what its voice command does.
struct FoodCheckCard: View {
  let tool: LabelsTool
  let allergens: MyAllergens
  @State private var editing = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Food check")
        .font(.rounded(.title2, weight: .heavy))
        .foregroundStyle(Theme.ink)
        .accessibilityAddTraits(.isHeader)

      Text(allergens.isEmpty ? "My allergens: none set yet." : "My allergens: \(FoodAllergens.spokenList(allergens.allergens)).")
        .font(.rounded(.title3, weight: .semibold))
        .foregroundStyle(Theme.ink)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("labels_my_allergens")

      Button("Is this OK for me?") { tool.perform(.foodCheck) }
        .buttonStyle(.a11ySecondary)
        .accessibilityHint("Checks the ingredients and allergy advice against your allergens. Nothing goes online.")
        .accessibilityIdentifier("labels_food_check")

      Button("Cooking steps") { tool.perform(.cooking) }
        .buttonStyle(.a11ySecondary)
        .accessibilityHint("Reads the cooking instructions one step at a time.")
        .accessibilityIdentifier("labels_cooking_steps")

      if tool.foodDate != nil, tool.canRemind {
        Button("Remind me before it goes off") { tool.perform(.remind) }
          .buttonStyle(.a11ySecondary)
          .accessibilityIdentifier("labels_remind")
      }

      Button(editing ? "Done changing allergens" : "Change my allergens") { editing.toggle() }
        .buttonStyle(.a11ySecondary)
        .accessibilityIdentifier("labels_edit_allergens")

      if editing {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(FoodAllergens.all) { allergen in
            Toggle(
              isOn: Binding(get: { allergens.contains(allergen) }, set: { tool.setAllergen(allergen, on: $0) })
            ) {
              Text(allergen.title)
                .font(.rounded(.title3, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 52)
            .accessibilityIdentifier("labels_allergen_\(allergen.id)")
          }
        }
      }
    }
    .themeCard()
  }
}
