/*
 * ImportButton - "Read a photo or PDF": pick a photo from Photos or a file from Files, and hear it
 *
 * On the tools home, under the seven tools, styled like their rows (CameraView):
 *
 *   ImportButton(subtitle: "...")
 *     .buttonStyle(.a11ySecondary)
 *
 * Tapping asks which picker (a confirmation dialog VoiceOver reads as a list). The picked item
 * goes through the ImportInbox like every other import and is read at once in Read text, as a
 * camera read is (TextReader.read(pages:source:)). Photos come through
 * PhotosPicker (no photo library permission needed: the picker runs out of process and hands
 * over only what was picked). Files come through the document picker, as a security-scoped copy.
 *
 * By voice, "read a photo", "read a file" and "import" open the same pickers or dialog through
 * ImportPicker, after a spoken line about what comes next (CameraView.handleVoice).
 */

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ImportButton: View {
  var title = "Read a photo or PDF"
  /// Set on the tools home: the button then looks like a tool row (coin, title, this line).
  var subtitle: String?

  @State private var choosing = false
  @State private var pickingPhoto = false
  @State private var pickingFile = false
  @State private var photo: PhotosPickerItem?
  /// Voice requests for the dialog or a picker (ImportPicker).
  var picker: ImportPicker = .shared

  var body: some View {
    Button {
      choosing = true
    } label: {
      if let subtitle {
        PathTileLabel(icon: "doc.text.image", title: title, value: subtitle, coin: .neutral)
      } else {
        Label(title, systemImage: "doc.text.image")
      }
    }
    // One element, named by its title. PathTileLabel hides itself from VoiceOver.
    .accessibilityLabel(title)
    .accessibilityHint("Choose a photo or a PDF to hear it read aloud.")
    .accessibilityIdentifier("importButton")
    .confirmationDialog(title, isPresented: $choosing, titleVisibility: .visible) {
      Button("Choose a photo") { pickingPhoto = true }
      Button("Choose a file") { pickingFile = true }
      Button("Cancel", role: .cancel) {}
    }
    .photosPicker(isPresented: $pickingPhoto, selection: $photo, matching: .images, preferredItemEncoding: .current)
    .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.pdf, .image]) { result in
      guard case .success(let url) = result else { return }
      if ImportedReading.addFile(url) { LaunchActionRouter.shared.request(.readImported) }
    }
    .onChange(of: photo) { _, item in
      guard let item else { return }
      photo = nil
      Task { await Self.importPhoto(item) }
    }
    // By voice ("read a photo", "read a file", "import"): CameraView parks the request after its
    // spoken line. `initial`: the button may only just have appeared, a tool having been open.
    .onChange(of: picker.pending, initial: true) { _, _ in takeVoiceRequest() }
  }

  /// Opens what a voice command asked for. From the choice, the dialog goes first, then the picker.
  private func takeVoiceRequest() {
    guard let request = picker.consume() else { return }
    let wasChoosing = choosing
    choosing = false
    let open = {
      switch request {
      case .choice: choosing = true
      case .photo: pickingPhoto = true
      case .file: pickingFile = true
      }
    }
    guard wasChoosing || pickingPhoto || pickingFile else { return open() }
    pickingPhoto = false
    pickingFile = false
    Task {
      try? await Task.sleep(for: .milliseconds(600))
      open()
    }
  }

  private static func importPhoto(_ item: PhotosPickerItem) async {
    EarconPlayer.shared.play(.working)
    guard let data = try? await item.loadTransferable(type: Data.self) else {
      Announcer.shared.say(SpokenMessage.importCouldNotOpen, kind: .reply)
      return
    }
    let fileExtension = item.supportedContentTypes.lazy.compactMap(\.preferredFilenameExtension).first ?? "jpg"
    guard (try? ImportedReading.inbox.add(data: data, fileExtension: fileExtension)) != nil else {
      Announcer.shared.say(SpokenMessage.importCouldNotOpen, kind: .reply)
      return
    }
    // Through the main screen, so Read text's panel opens and shows the page as it is read.
    LaunchActionRouter.shared.request(.readImported)
  }
}
