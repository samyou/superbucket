import SwiftUI
import Sparkle

/// Single place that owns the app's model objects, so the SwiftUI scenes and the AppKit delegate share them.
@MainActor
final class AppContainer {
    static let shared = AppContainer()
    let settings: AppSettings
    let uploads: UploadManager

    private init() {
        settings = AppSettings()
        uploads = UploadManager(settings: settings)
    }
}

@main
struct SuperBucketApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: AppSettings = AppContainer.shared.settings
    @StateObject private var uploads: UploadManager = AppContainer.shared.uploads
    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        // Only start Sparkle inside a real .app bundle; `swift run` has no Info.plist feed to read.
        if Bundle.main.bundleIdentifier != nil, Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            updaterController.startUpdater()
        }
    }

    var body: some Scene {
        WindowGroup("SuperBucket") {
            ContentView()
                .environmentObject(settings)
                .environmentObject(uploads)
                .frame(minWidth: 460, minHeight: 380)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            CommandGroup(after: .newItem) {
                Button("Add Files…") { NotificationCenter.default.post(name: .openFilePicker, object: nil) }
                    .keyboardShortcut("o")
            }
            CommandMenu("Uploads") {
                Button("Clear Finished") { uploads.clearFinished() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .disabled(!uploads.hasFinished)
                Button("Retry Failed") { uploads.retryAllFailed() }
                Button("Cancel All") { uploads.cancelAll() }
                    .disabled(uploads.activeCount == 0)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
        }
    }
}

extension Notification.Name {
    static let openFilePicker = Notification.Name("SuperBucket.openFilePicker")
}
