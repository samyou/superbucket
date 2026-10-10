import SwiftUI
import Sparkle

/// "Check for Updates…" menu item, enabled only when Sparkle is ready.
struct CheckForUpdatesView: View {
    @ObservedObject private var model: Model
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        model = Model(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!model.canCheckForUpdates)
    }

    final class Model: ObservableObject {
        @Published var canCheckForUpdates = false
        init(updater: SPUUpdater) {
            updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        }
    }
}
