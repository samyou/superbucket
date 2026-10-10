import Foundation
import SwiftUI
import UniformTypeIdentifiers
import SuperBucketCore

struct UploadItem: Identifiable, Equatable {
    enum Status: Equatable {
        case queued
        case uploading
        case done(URL)
        case skipped(URL)
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let fileURL: URL
    let key: String
    let size: Int64
    var bytesSent: Int64 = 0
    var status: Status = .queued
    /// Upload even if an identical object already exists.
    var force = false

    var fileName: String { fileURL.lastPathComponent }
    var fraction: Double { size > 0 ? min(1, Double(bytesSent) / Double(size)) : 0 }
    var isActive: Bool { status == .queued || status == .uploading }
    var isFinished: Bool {
        switch status {
        case .done, .skipped, .cancelled: return true
        default: return false
        }
    }
}

@MainActor
final class UploadManager: ObservableObject {
    @Published private(set) var items: [UploadItem] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    var activeCount: Int { items.filter(\.isActive).count }
    var uploadingCount: Int { items.filter { $0.status == .uploading }.count }
    var queuedCount: Int { items.filter { $0.status == .queued }.count }
    var hasFinished: Bool { items.contains(where: \.isFinished) }

    // MARK: Enqueue

    /// Adds dropped files and folders. Folders are walked recursively and keep their relative paths.
    func add(urls: [URL]) {
        let prefix = settings.normalizedPrefix
        Task.detached(priority: .userInitiated) {
            var newItems: [UploadItem] = []
            for url in urls {
                newItems.append(contentsOf: Self.expand(url, prefix: prefix))
            }
            let found = newItems
            await MainActor.run {
                self.items.append(contentsOf: found)
                self.pump()
            }
        }
    }

    nonisolated private static func expand(_ url: URL, prefix: String) -> [UploadItem] {
        let fm = FileManager.default
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values?.isDirectory == true {
            guard let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return [] }
            let base = url.standardizedFileURL.path
            var result: [UploadItem] = []
            for case let child as URL in enumerator {
                let v = try? child.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard v?.isRegularFile == true else { continue }
                var relative = child.standardizedFileURL.path
                if relative.hasPrefix(base) { relative.removeFirst(base.count) }
                while relative.hasPrefix("/") { relative.removeFirst() }
                let key = prefix + url.lastPathComponent + "/" + relative
                result.append(UploadItem(fileURL: child, key: key, size: Int64(v?.fileSize ?? 0)))
            }
            return result
        }
        return [UploadItem(fileURL: url, key: prefix + url.lastPathComponent, size: Int64(values?.fileSize ?? 0))]
    }

    // MARK: Scheduling

    private func pump() {
        guard let client = settings.makeClient() else {
            for i in items.indices where items[i].status == .queued {
                items[i].status = .failed("Not configured. Open Settings and enter your bucket and access key.")
            }
            return
        }
        let running = items.filter { $0.status == .uploading }.count
        var slots = max(1, settings.maxConcurrent) - running
        for i in items.indices where slots > 0 && items[i].status == .queued {
            slots -= 1
            start(items[i], client: client)
        }
    }

    private func start(_ item: UploadItem, client: TigrisClient) {
        update(item.id) { $0.status = .uploading; $0.bytesSent = 0 }
        let id = item.id
        let contentType = UTType(filenameExtension: item.fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"

        let skipExisting = settings.conflictPolicy == .skip && !item.force

        tasks[id] = Task { [weak self] in
            do {
                if skipExisting, let existing = try await client.headObject(key: item.key), existing.size == item.size {
                    self?.update(id) { $0.bytesSent = $0.size; $0.status = .skipped(client.objectURL(key: item.key)) }
                } else {
                    let result = try await client.uploadFile(fileURL: item.fileURL, key: item.key, contentType: contentType) { [weak self] sent, _ in
                        Task { @MainActor in
                            self?.update(id) { $0.bytesSent = sent }
                        }
                    }
                    self?.update(id) { $0.bytesSent = $0.size; $0.status = .done(result.url) }
                }
            } catch is CancellationError {
                self?.update(id) { $0.status = .cancelled }
            } catch let error as URLError where error.code == .cancelled {
                self?.update(id) { $0.status = .cancelled }
            } catch {
                self?.update(id) { $0.status = .failed(error.localizedDescription) }
            }
            self?.tasks[id] = nil
            self?.pump()
        }
    }

    private func update(_ id: UUID, _ change: (inout UploadItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
    }

    // MARK: Actions

    func cancel(_ id: UUID) {
        if let task = tasks[id] {
            task.cancel()
        } else {
            update(id) { if $0.status == .queued { $0.status = .cancelled } }
        }
    }

    func retry(_ id: UUID, force: Bool = false) {
        update(id) { $0.status = .queued; $0.bytesSent = 0; if force { $0.force = true } }
        pump()
    }

    func retryAllFailed() {
        for i in items.indices {
            if case .failed = items[i].status { items[i].status = .queued; items[i].bytesSent = 0 }
        }
        pump()
    }

    func remove(_ id: UUID) {
        tasks[id]?.cancel()
        items.removeAll { $0.id == id }
    }

    func clearFinished() {
        items.removeAll(where: \.isFinished)
    }

    func cancelAll() {
        for (_, task) in tasks { task.cancel() }
        for i in items.indices where items[i].status == .queued { items[i].status = .cancelled }
    }

    func presignedURL(for item: UploadItem) -> URL? {
        settings.makeClient()?.presignedGetURL(key: item.key)
    }
}
