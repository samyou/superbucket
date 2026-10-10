import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var uploads: UploadManager
    @State private var isTargeted = false
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if uploads.items.isEmpty {
                DropZoneView(isTargeted: isTargeted, onChoose: chooseFiles)
            } else {
                uploadList
            }
        }
        .overlay {
            if isTargeted && !uploads.items.isEmpty {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.08))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            uploads.add(urls: files)
            return true
        } isTargeted: { isTargeted = $0 }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(settings)
        }
        .onAppear {
            if !settings.isConfigured { showSettings = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFilePicker)) { _ in chooseFiles() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.icloud")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(settings.bucket.isEmpty ? "No bucket configured" : settings.bucket)
                    .font(.headline)
                Text(destinationDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if uploads.activeCount > 0 {
                ProgressView().controlSize(.small)
                Text(uploads.queuedCount > 0
                     ? "\(uploads.uploadingCount) uploading · \(uploads.queuedCount) queued"
                     : "\(uploads.uploadingCount) uploading")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(action: chooseFiles) {
                Label("Add Files", systemImage: "plus")
            }
            .help("Choose files or folders to upload (⌘O)")
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var destinationDescription: String {
        guard let host = URL(string: settings.endpoint)?.host else { return settings.endpoint }
        let prefix = settings.normalizedPrefix
        return prefix.isEmpty ? host : "\(host) · \(prefix)"
    }

    private var uploadList: some View {
        VStack(spacing: 0) {
            List {
                ForEach(uploads.items) { item in
                    UploadRowView(item: item)
                        .listRowSeparator(.visible)
                }
            }
            .listStyle(.inset)
            Divider()
            HStack {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Retry Failed") { uploads.retryAllFailed() }
                    .disabled(!uploads.items.contains { if case .failed = $0.status { return true }; return false })
                Button("Clear Finished") { uploads.clearFinished() }
                    .disabled(!uploads.hasFinished)
            }
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    private var summary: String {
        let done = uploads.items.filter { if case .done = $0.status { return true }; return false }.count
        let skipped = uploads.items.filter { if case .skipped = $0.status { return true }; return false }.count
        let failed = uploads.items.filter { if case .failed = $0.status { return true }; return false }.count
        var parts = ["\(done) of \(uploads.items.count) uploaded"]
        if skipped > 0 { parts.append("\(skipped) already existed") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: " · ")
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.message = "Choose files or folders to upload to \(settings.bucket)"
        if panel.runModal() == .OK {
            uploads.add(urls: panel.urls)
        }
    }
}
