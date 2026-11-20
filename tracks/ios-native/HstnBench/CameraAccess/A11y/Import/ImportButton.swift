/*
 * ImportButton - "Read a photo or PDF": pick a photo from Photos or a file from Files, and hear it
 *
 * For the tools home to place; it has no layout of its own beyond its label, so the caller gives
 * it the style of the buttons around it:
 *
 *   ImportButton()
 *     .buttonStyle(ChunkyButtonStyle(...))
 *
 * Tapping asks which picker (a confirmation dialog VoiceOver reads as a list). The picked item
 * goes through the ImportInbox like every other import and is read at once. Photos come through
 * PhotosPicker (no photo library permission needed: the picker runs out of process and hands
 * over only what was picked). Files come through the document picker, as a security-scoped copy.
 */

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ImportButton: View {
  var title = "Read a photo or PDF"

  @State private var choosing = false
  @State private var pickingPhoto = false
  @State private var pickingFile = false
  @State private var photo: PhotosPickerItem?

  var body: some View {
    Button {
      choosing = true
    } label: {
      Label(title, systemImage: "doc.text.image")
    }
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
      if ImportedReading.addFile(url) { ImportedReading.readPending() }
    }
    .onChange(of: photo) { _, item in
      guard let item else { return }
      photo = nil
      Task { await Self.importPhoto(item) }
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
    ImportedReading.readPending()
  }
}
