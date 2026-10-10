import Foundation
import SwiftUI
import SuperBucketCore

/// Persisted connection settings. Non-secret fields live in UserDefaults, the secret key in the Keychain.
@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let endpoint = "endpoint"
        static let bucket = "bucket"
        static let prefix = "prefix"
        static let accessKeyID = "accessKeyID"
        static let pathStyle = "pathStyle"
        static let maxConcurrent = "maxConcurrent"
        static let secret = "secretAccessKey"
        static let conflictPolicy = "conflictPolicy"
        static let showMenuBarIcon = "showMenuBarIcon"
    }

    enum ConflictPolicy: String, CaseIterable, Identifiable {
        case skip, overwrite
        var id: String { rawValue }
        var label: String {
            switch self {
            case .skip: return "Skip if same size already exists"
            case .overwrite: return "Always overwrite"
            }
        }
    }

    @Published var endpoint: String { didSet { defaults.set(endpoint, forKey: Key.endpoint) } }
    @Published var bucket: String { didSet { defaults.set(bucket, forKey: Key.bucket) } }
    /// Optional key prefix, e.g. `uploads/`.
    @Published var prefix: String { didSet { defaults.set(prefix, forKey: Key.prefix) } }
    @Published var accessKeyID: String { didSet { defaults.set(accessKeyID, forKey: Key.accessKeyID) } }
    @Published var secretAccessKey: String { didSet { Keychain.set(secretAccessKey, for: Key.secret) } }
    @Published var pathStyle: Bool { didSet { defaults.set(pathStyle, forKey: Key.pathStyle) } }
    @Published var maxConcurrent: Int { didSet { defaults.set(maxConcurrent, forKey: Key.maxConcurrent) } }
    @Published var conflictPolicy: ConflictPolicy { didSet { defaults.set(conflictPolicy.rawValue, forKey: Key.conflictPolicy) } }
    @Published var showMenuBarIcon: Bool { didSet { defaults.set(showMenuBarIcon, forKey: Key.showMenuBarIcon) } }

    private let defaults = UserDefaults.standard

    init() {
        endpoint = defaults.string(forKey: Key.endpoint) ?? TigrisConfig.defaultEndpoint.absoluteString
        bucket = defaults.string(forKey: Key.bucket) ?? ""
        prefix = defaults.string(forKey: Key.prefix) ?? ""
        accessKeyID = defaults.string(forKey: Key.accessKeyID) ?? ""
        secretAccessKey = Keychain.get(Key.secret) ?? ""
        pathStyle = defaults.bool(forKey: Key.pathStyle)
        let stored = defaults.integer(forKey: Key.maxConcurrent)
        maxConcurrent = stored == 0 ? 3 : stored
        conflictPolicy = ConflictPolicy(rawValue: defaults.string(forKey: Key.conflictPolicy) ?? "") ?? .skip
        showMenuBarIcon = defaults.object(forKey: Key.showMenuBarIcon) == nil ? true : defaults.bool(forKey: Key.showMenuBarIcon)
    }

    var isConfigured: Bool {
        makeConfig() != nil
    }

    /// Tolerates pasting a whole `.env` line (`NAME=value`), surrounding quotes, and stray whitespace.
    static func cleanCredential(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let eq = s.lastIndex(of: "=") {
            s = String(s[s.index(after: eq)...])
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t\n\r"))
        return s
    }

    var cleanAccessKeyID: String { Self.cleanCredential(accessKeyID) }
    var cleanSecretAccessKey: String { Self.cleanCredential(secretAccessKey) }

    /// A human-readable problem with the current credentials, if any.
    var credentialWarning: String? {
        let id = cleanAccessKeyID, secret = cleanSecretAccessKey
        if !id.isEmpty && !id.hasPrefix("tid_") { return "Tigris access key IDs start with tid_" }
        if !secret.isEmpty && !secret.hasPrefix("tsec_") { return "Tigris secret keys start with tsec_" }
        if !secret.isEmpty && secret.count < 20 { return "The secret key looks too short" }
        return nil
    }

    func makeConfig() -> TigrisConfig? {
        let trimmedBucket = bucket.trimmingCharacters(in: .whitespaces)
        let id = cleanAccessKeyID
        let secret = cleanSecretAccessKey
        guard !trimmedBucket.isEmpty, !id.isEmpty, !secret.isEmpty,
              let url = URL(string: endpoint.trimmingCharacters(in: .whitespaces)), url.host != nil else {
            return nil
        }
        return TigrisConfig(
            endpoint: url,
            bucket: trimmedBucket,
            pathStyle: pathStyle,
            credentials: AWSCredentials(accessKeyID: id, secretAccessKey: secret)
        )
    }

    func makeClient() -> TigrisClient? {
        makeConfig().map { TigrisClient(config: $0) }
    }

    /// Normalised prefix: no leading slash, exactly one trailing slash when non-empty.
    var normalizedPrefix: String {
        var p = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        while p.hasPrefix("/") { p.removeFirst() }
        if !p.isEmpty && !p.hasSuffix("/") { p += "/" }
        return p
    }
}
