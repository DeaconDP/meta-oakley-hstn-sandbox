/*
 * ImportLaunchHandling - the app-level hooks for imports, attached once in CameraAccessApp with
 * `.readsImports()`
 *
 * - onOpenURL: a photo or PDF opened in SpeakUp from Files or another app ("Open in", "Copy to"),
 *   and speakup://read-imported. Other URLs (hands-free, Meta AI's callback) are left alone; every
 *   onOpenURL handler in the scene sees every URL, so their own handlers still get them.
 * - Coming to the front: anything the share extension left is read (it can't open the app).
 *
 * Both only park LaunchAction.readImported; the main screen runs it once it is up.
 */

import SwiftUI

struct ImportLaunchHandling: ViewModifier {
  @Environment(\.scenePhase) private var scenePhase

  func body(content: Content) -> some View {
    content
      .onOpenURL { url in ImportedReading.handle(url) }
      .onChange(of: scenePhase, initial: true) { _, phase in
        if phase == .active { ImportedReading.appBecameActive() }
      }
  }
}

extension View {
  /// Reads photos and PDFs handed to the app. Attach once, to the root view.
  func readsImports() -> some View { modifier(ImportLaunchHandling()) }
}
