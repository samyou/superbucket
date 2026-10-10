import SwiftUI
import SuperBucketCore

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    private enum TestState: Equatable {
        case idle, testing, ok, failed(String)
    }
    @State private var testState: TestState = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Bucket") {
                    TextField("Bucket name", text: $settings.bucket, prompt: Text("my-bucket"))
                    TextField("Key prefix (optional)", text: $settings.prefix, prompt: Text("uploads/"))
                }
                Section("Access Key") {
                    TextField("Access Key ID", text: $settings.accessKeyID, prompt: Text("tid_…"))
                    SecureField("Secret Access Key", text: $settings.secretAccessKey, prompt: Text("tsec_…"))
                    if let warning = settings.credentialWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text("Create one with `tigris access-keys create <name> -b <bucket> -r ReadWrite` or in the Tigris console. The secret is stored in your Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Behavior") {
                    Picker("If the object already exists", selection: $settings.conflictPolicy) {
                        ForEach(AppSettings.ConflictPolicy.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Show icon in menu bar (drop files on it)", isOn: $settings.showMenuBarIcon)
                }
                Section("Advanced") {
                    TextField("Endpoint", text: $settings.endpoint, prompt: Text(TigrisConfig.defaultEndpoint.absoluteString))
                    Toggle("Use path-style URLs", isOn: $settings.pathStyle)
                    Stepper("Parallel uploads: \(settings.maxConcurrent)", value: $settings.maxConcurrent, in: 1...8)
                }
            }
            .formStyle(.grouped)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()

            Divider()
            HStack {
                Button("Test Connection") { test() }
                    .disabled(!settings.isConfigured || testState == .testing)
                switch testState {
                case .idle: EmptyView()
                case .testing: ProgressView().controlSize(.small)
                case .ok: Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed(let msg):
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .help(msg)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 520, height: 560)
        .onChange(of: settings.bucket) { _, _ in testState = .idle }
        .onChange(of: settings.accessKeyID) { _, _ in testState = .idle }
        .onChange(of: settings.secretAccessKey) { _, _ in testState = .idle }
        .onChange(of: settings.endpoint) { _, _ in testState = .idle }
    }

    private func test() {
        guard let client = settings.makeClient() else { return }
        testState = .testing
        Task {
            do {
                try await client.headBucket()
                testState = .ok
            } catch {
                testState = .failed(error.localizedDescription)
            }
        }
    }
}
