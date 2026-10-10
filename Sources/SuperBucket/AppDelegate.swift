import AppKit
import Combine

/// AppKit glue: menu bar drop target and "open with" / `open -a SuperBucket file` support.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let container = AppContainer.shared
        container.settings.$showMenuBarIcon
            .receive(on: DispatchQueue.main)
            .sink { [weak self] show in self?.setStatusItemVisible(show) }
            .store(in: &cancellables)
        container.uploads.$items
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in
                let active = items.filter(\.isActive).count
                self?.statusItem?.button?.title = active > 0 ? " \(active)" : ""
            }
            .store(in: &cancellables)
    }

    /// Files handed to us by Finder's "Open With", a Shortcuts quick action, or `open -a SuperBucket <files>`.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        AppContainer.shared.uploads.add(urls: files)
        Self.showMainWindow()
    }

    private func setStatusItemVisible(_ visible: Bool) {
        if visible, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = item.button {
                button.image = NSImage(systemSymbolName: "arrow.up.doc", accessibilityDescription: "SuperBucket")
                button.imagePosition = .imageLeading
                button.toolTip = "Drop files here to upload to Tigris"
                let drop = StatusDropView(frame: button.bounds)
                drop.autoresizingMask = [.width, .height]
                button.addSubview(drop)
            }
            statusItem = item
        } else if !visible, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    static func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title == "SuperBucket" && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        // No window: ask ourselves to reopen, which makes SwiftUI recreate the WindowGroup window.
        let target = NSAppleEventDescriptor(processIdentifier: ProcessInfo.processInfo.processIdentifier)
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
            targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
        )
        _ = try? event.sendEvent(options: [.noReply], timeout: 1)
    }
}

/// Transparent view over the status item button that accepts file drops and forwards clicks.
final class StatusDropView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        AppContainer.shared.uploads.add(urls: urls)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        AppDelegate.showMainWindow()
    }

    private func fileURLs(from info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}
