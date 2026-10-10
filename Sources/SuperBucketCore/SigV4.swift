import Foundation
import CryptoKit

/// Access key pair used to sign S3 requests. Tigris keys look like `tid_…` / `tsec_…`.
public struct AWSCredentials: Sendable, Equatable {
    public var accessKeyID: String
    public var secretAccessKey: String

    public init(accessKeyID: String, secretAccessKey: String) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
    }
}

/// Minimal AWS Signature Version 4 implementation (header and query-string signing).
public enum SigV4 {
    public static let unsignedPayload = "UNSIGNED-PAYLOAD"
    public static let emptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"
    )

    /// URI-encodes per the SigV4 rules. Slashes are preserved only when `allowSlash` is set (object paths).
    public static func encode(_ value: String, allowSlash: Bool = false) -> String {
        var allowed = unreserved
        if allowSlash { allowed.insert("/") }
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    public static func hexSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func amzDate(_ date: Date) -> (full: String, short: String) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let full = f.string(from: date)
        return (full, String(full.prefix(8)))
    }

    static func hmac(_ key: Data, _ message: String) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key))
        return Data(mac)
    }

    static func signingKey(secret: String, shortDate: String, region: String, service: String) -> Data {
        let kDate = hmac(Data("AWS4\(secret)".utf8), shortDate)
        let kRegion = hmac(kDate, region)
        let kService = hmac(kRegion, service)
        return hmac(kService, "aws4_request")
    }

    static func hostHeader(for url: URL) -> String {
        guard let host = url.host else { return "" }
        if let port = url.port, !((url.scheme == "https" && port == 443) || (url.scheme == "http" && port == 80)) {
            return "\(host):\(port)"
        }
        return host
    }

    /// Canonical query string: each name/value URI-encoded, sorted by name then value.
    static func canonicalQuery(from url: URL) -> String {
        guard let raw = url.query, !raw.isEmpty else { return "" }
        let pairs: [(String, String)] = raw.split(separator: "&", omittingEmptySubsequences: true).map { part in
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            return (encode(name), encode(value))
        }
        return pairs.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
    }

    static func canonicalURI(for url: URL) -> String {
        let path = url.path.isEmpty ? "/" : url.path
        return encode(path, allowSlash: true)
    }

    /// Signs `request` in place by adding `x-amz-date` and `Authorization` headers.
    /// `request.url` must already contain the final (percent-encoded) path and query.
    /// All headers present on the request at call time are signed.
    public static func sign(
        _ request: inout URLRequest,
        credentials: AWSCredentials,
        region: String,
        service: String = "s3",
        payloadHash: String,
        date: Date = Date()
    ) {
        guard let url = request.url else { return }
        let (fullDate, shortDate) = amzDate(date)
        request.setValue(fullDate, forHTTPHeaderField: "x-amz-date")
        if service == "s3" {
            request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        }

        var headers: [String: String] = [:]
        for (k, v) in request.allHTTPHeaderFields ?? [:] {
            headers[k.lowercased()] = v.trimmingCharacters(in: .whitespaces)
        }
        headers["host"] = hostHeader(for: url)

        let sortedNames = headers.keys.sorted()
        let canonicalHeaders = sortedNames.map { "\($0):\(headers[$0]!)\n" }.joined()
        let signedHeaders = sortedNames.joined(separator: ";")

        let canonicalRequest = [
            request.httpMethod ?? "GET",
            canonicalURI(for: url),
            canonicalQuery(from: url),
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(shortDate)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            fullDate,
            scope,
            hexSHA256(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let key = signingKey(secret: credentials.secretAccessKey, shortDate: shortDate, region: region, service: service)
        let signature = hmac(key, stringToSign).map { String(format: "%02x", $0) }.joined()

        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
    }

    /// Builds a presigned URL (query-string authentication). `url` must have no query of its own.
    public static func presign(
        method: String,
        url: URL,
        credentials: AWSCredentials,
        region: String,
        service: String = "s3",
        expires: Int,
        date: Date = Date()
    ) -> URL {
        let (fullDate, shortDate) = amzDate(date)
        let scope = "\(shortDate)/\(region)/\(service)/aws4_request"
        let host = hostHeader(for: url)

        let query: [(String, String)] = [
            ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
            ("X-Amz-Credential", "\(credentials.accessKeyID)/\(scope)"),
            ("X-Amz-Date", fullDate),
            ("X-Amz-Expires", String(expires)),
            ("X-Amz-SignedHeaders", "host"),
        ]
        let canonicalQuery = query
            .map { "\(encode($0.0))=\(encode($0.1))" }
            .sorted()
            .joined(separator: "&")

        let canonicalRequest = [
            method,
            canonicalURI(for: url),
            canonicalQuery,
            "host:\(host)\n",
            "host",
            unsignedPayload,
        ].joined(separator: "\n")

        let stringToSign = [
            "AWS4-HMAC-SHA256",
            fullDate,
            scope,
            hexSHA256(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let key = signingKey(secret: credentials.secretAccessKey, shortDate: shortDate, region: region, service: service)
        let signature = hmac(key, stringToSign).map { String(format: "%02x", $0) }.joined()

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = canonicalQuery + "&X-Amz-Signature=\(signature)"
        return components.url!
    }
}
