/*
 * ShareViewController - "SpeakUp Share": hand SpeakUp a photo, screenshot or PDF from any app
 *
 * iOS doesn't let a share extension open its app (only Today and iMessage extensions may call
 * openURL), so this doesn't try. It copies what was shared into the App Group inbox
 * (ImportInbox), says "Saved. Open SpeakUp to hear it." and closes when the user taps Done. The
 * app reads the inbox when it next comes to the front (ImportedReading.appBecameActive).
 *
 * Nothing is read or sent from here: the extension only copies files. Share extensions get about
 * 120 MB of memory, so files are copied, not decoded.
 */

import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
  private let model = ShareModel()

  override func viewDidLoad() {
    super.viewDidLoad()
    let host = UIHostingController(rootView: ShareView(model: model) { [weak self] in self?.done() })
    addChild(host)
    host.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(host.view)
    NSLayoutConstraint.activate([
      host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      host.view.topAnchor.constraint(equalTo: view.topAnchor),
      host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    host.didMove(toParent: self)

    let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
      .flatMap { $0.attachments ?? [] }
    Task { @MainActor in
      let saved = await ShareSaver.save(providers, to: ImportInbox.shared)
      model.finish(saved: saved)
    }
  }

  private func done() {
    extensionContext?.completeRequest(returningItems: nil)
  }
}

@MainActor
final class ShareModel: ObservableObject {
  enum State: Equatable {
    case saving
    case saved(Int)
    case nothing
  }

  @Published var state = State.saving

  func finish(saved: Int) {
    state = saved > 0 ? .saved(saved) : .nothing
    UIAccessibility.post(notification: .announcement, argument: message)
  }

  var message: String {
    switch state {
    case .saving: "Saving for SpeakUp."
    case .saved(1): "Saved. Open SpeakUp to hear it."
    case .saved: "Saved. Open SpeakUp to hear them."
    case .nothing: "SpeakUp reads photos and PDFs. There was nothing like that to save."
    }
  }
}

struct ShareView: View {
  @ObservedObject var model: ShareModel
  var onDone: () -> Void

  var body: some View {
    VStack(spacing: 24) {
      Spacer()
      Image(systemName: model.state == .nothing ? "exclamationmark.circle" : "speaker.wave.2.fill")
        .font(.system(size: 56, weight: .bold))
        .accessibilityHidden(true)
      Text(model.message)
        .font(.title.bold())
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      if model.state == .saving {
        ProgressView().controlSize(.large)
      }
      Spacer()
      Button(action: onDone) {
        Text("Done")
          .font(.title2.bold())
          .frame(maxWidth: .infinity, minHeight: 56)
      }
      .buttonStyle(.borderedProminent)
      .disabled(model.state == .saving)
      .accessibilityIdentifier("shareDone")
    }
    .padding(24)
    .background(Color(.systemBackground))
  }
}

/// Copies every photo or PDF among `providers` into the inbox. Returns how many were saved.
enum ShareSaver {
  static func save(_ providers: [NSItemProvider], to inbox: ImportInbox) async -> Int {
    var saved = 0
    for provider in providers {
      guard let (type, kind) = pick(provider.registeredTypeIdentifiers) else { continue }
      if let data = await loadData(provider, type: type) {
        let fileExtension = type.preferredFilenameExtension ?? (kind == .pdf ? "pdf" : "png")
        if (try? inbox.add(data: data, fileExtension: fileExtension)) != nil { saved += 1 }
      } else if kind == .image, let png = await loadImagePNG(provider) {
        // Screenshots from the markup editor arrive as a UIImage object, not a file.
        if (try? inbox.add(data: png, fileExtension: "png")) != nil { saved += 1 }
      }
    }
    return saved
  }

  /// The first registered type that is a PDF or an image with a known file extension. A plain
  /// "public.image" (no extension) is read as a UIImage instead.
  static func pick(_ identifiers: [String]) -> (UTType, ImportInbox.Kind)? {
    let types = identifiers.compactMap(UTType.init)
    if let pdf = types.first(where: { $0.conforms(to: .pdf) }) { return (pdf, .pdf) }
    if let image = types.first(where: { $0.conforms(to: .image) && $0.preferredFilenameExtension != nil }) {
      return (image, .image)
    }
    if let image = types.first(where: { $0.conforms(to: .image) }) { return (image, .image) }
    return nil
  }

  private static func loadData(_ provider: NSItemProvider, type: UTType) async -> Data? {
    guard type.preferredFilenameExtension != nil else { return nil }
    return await withCheckedContinuation { continuation in
      _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
        continuation.resume(returning: data)
      }
    }
  }

  private static func loadImagePNG(_ provider: NSItemProvider) async -> Data? {
    guard provider.canLoadObject(ofClass: UIImage.self) else { return nil }
    return await withCheckedContinuation { continuation in
      _ = provider.loadObject(ofClass: UIImage.self) { object, _ in
        continuation.resume(returning: (object as? UIImage)?.pngData())
      }
    }
  }
}
