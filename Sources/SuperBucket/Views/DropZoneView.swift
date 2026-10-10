import SwiftUI

struct DropZoneView: View {
    let isTargeted: Bool
    let onChoose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: isTargeted ? "arrow.down.doc.fill" : "arrow.up.doc")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
                .symbolEffect(.bounce, value: isTargeted)
            Text(isTargeted ? "Release to upload" : "Drop files or folders here")
                .font(.title3.weight(.medium))
            Text("Files are uploaded straight to your Tigris bucket.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Choose Files…", action: onChoose)
                .buttonStyle(.bordered)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                )
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
                )
                .padding(16)
        }
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
    }
}
