import SwiftUI
import AppKit

struct UploadRowView: View {
    @EnvironmentObject private var uploads: UploadManager
    let item: UploadItem
    @State private var copied = false

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.fileURL.path))
                .resizable()
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.fileName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                }
                Text(item.key)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.key)
                if item.status == .uploading {
                    ProgressView(value: item.fraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
                if case .failed(let message) = item.status {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .help(message)
                }
            }

            actions
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 4) {
            switch item.status {
            case .queued, .uploading:
                Button { uploads.cancel(item.id) } label: { Image(systemName: "xmark.circle") }
                    .help("Cancel")
            case .done(let url), .skipped(let url):
                if case .skipped = item.status {
                    Button { uploads.retry(item.id, force: true) } label: { Image(systemName: "arrow.up.circle") }
                        .help("Upload anyway, replacing the existing object")
                }
                Menu {
                    Button("Copy Public URL") { copy(url.absoluteString) }
                    Button("Copy Presigned Link (7 days)") {
                        if let signed = uploads.presignedURL(for: item) { copy(signed.absoluteString) }
                    }
                    Divider()
                    Button("Open in Browser") {
                        if let signed = uploads.presignedURL(for: item) { NSWorkspace.shared.open(signed) }
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "link")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Copy link")
                Button { uploads.remove(item.id) } label: { Image(systemName: "trash") }
                    .help("Remove from list")
            case .failed, .cancelled:
                Button { uploads.retry(item.id) } label: { Image(systemName: "arrow.clockwise") }
                    .help("Retry")
                Button { uploads.remove(item.id) } label: { Image(systemName: "trash") }
                    .help("Remove from list")
            }
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
    }

    private var statusText: String {
        let size = ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
        switch item.status {
        case .queued: return "Queued · \(size)"
        case .uploading:
            let sent = ByteCountFormatter.string(fromByteCount: item.bytesSent, countStyle: .file)
            return "\(sent) of \(size)"
        case .done: return "Uploaded · \(size)"
        case .skipped: return "Already exists · \(size)"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .done: return .green
        case .failed: return .red
        case .skipped, .cancelled: return .orange
        default: return .secondary
        }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}
