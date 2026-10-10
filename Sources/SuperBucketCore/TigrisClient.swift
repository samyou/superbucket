import Foundation

/// Connection settings for a Tigris bucket.
public struct TigrisConfig: Sendable, Equatable {
    public static let defaultEndpoint = URL(string: "https://t3.storage.dev")!

    public var endpoint: URL
    public var region: String
    public var bucket: String
    /// `false` uses virtual-hosted URLs (`https://bucket.t3.storage.dev/key`), which Tigris recommends.
    public var pathStyle: Bool
    public var credentials: AWSCredentials

    public init(
        endpoint: URL = TigrisConfig.defaultEndpoint,
        region: String = "auto",
        bucket: String,
        pathStyle: Bool = false,
        credentials: AWSCredentials
    ) {
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.pathStyle = pathStyle
        self.credentials = credentials
    }
}

public struct TigrisError: Error, LocalizedError, Sendable {
    public var statusCode: Int
    public var code: String?
    public var message: String?

    public var errorDescription: String? {
        var parts: [String] = ["HTTP \(statusCode)"]
        if let code { parts.append(code) }
        if let message { parts.append(message) }
        switch code {
        case "SignatureDoesNotMatch": parts.append("Check the Secret Access Key in Settings.")
        case "InvalidAccessKeyId": parts.append("Check the Access Key ID in Settings.")
        case "AccessDenied": parts.append("The key has no write access to this bucket.")
        case "NoSuchBucket": parts.append("Check the bucket name in Settings.")
        default: break
        }
        return parts.joined(separator: " – ")
    }

    static func from(response: HTTPURLResponse, body: Data) -> TigrisError {
        let text = String(decoding: body, as: UTF8.self)
        func tag(_ name: String) -> String? {
            guard let open = text.range(of: "<\(name)>"), let close = text.range(of: "</\(name)>"),
                  open.upperBound <= close.lowerBound else { return nil }
            return String(text[open.upperBound..<close.lowerBound])
        }
        return TigrisError(statusCode: response.statusCode, code: tag("Code"), message: tag("Message"))
    }
}

public struct PutObjectResult: Sendable {
    public var key: String
    public var etag: String?
    public var url: URL
}

/// A small S3 client that talks to Tigris. Only the operations the app needs.
public final class TigrisClient: Sendable {
    public let config: TigrisConfig
    let session: URLSession

    public init(config: TigrisConfig, session: URLSession? = nil) {
        self.config = config
        self.session = session ?? Self.makeSession()
    }

    /// Long timeouts: a multi-GB upload sends for minutes before the server replies.
    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 3600
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        configuration.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: configuration)
    }

    // MARK: URLs

    /// Unsigned URL of an object. Resolves only if the bucket (or object) is public.
    public func objectURL(key: String) -> URL {
        var components = URLComponents()
        components.scheme = config.endpoint.scheme
        components.port = config.endpoint.port
        let encodedKey = SigV4.encode(key, allowSlash: true)
        if config.pathStyle {
            components.host = config.endpoint.host
            components.percentEncodedPath = "/\(config.bucket)/\(encodedKey)"
        } else {
            components.host = "\(config.bucket).\(config.endpoint.host ?? "")"
            components.percentEncodedPath = "/\(encodedKey)"
        }
        return components.url!
    }

    private func bucketURL() -> URL {
        var components = URLComponents()
        components.scheme = config.endpoint.scheme
        components.port = config.endpoint.port
        if config.pathStyle {
            components.host = config.endpoint.host
            components.percentEncodedPath = "/\(config.bucket)/"
        } else {
            components.host = "\(config.bucket).\(config.endpoint.host ?? "")"
            components.percentEncodedPath = "/"
        }
        return components.url!
    }

    /// Presigned GET URL. Max expiry S3 allows is 7 days.
    public func presignedGetURL(key: String, expires: TimeInterval = 7 * 24 * 3600) -> URL {
        SigV4.presign(
            method: "GET",
            url: objectURL(key: key),
            credentials: config.credentials,
            region: config.region,
            expires: Int(min(expires, 604_800))
        )
    }

    // MARK: Operations

    /// Uploads a local file with a single PUT. Progress reports (bytesSent, totalBytes).
    public func putObject(
        fileURL: URL,
        key: String,
        contentType: String? = nil,
        progress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> PutObjectResult {
        let url = objectURL(key: key)
        var request = URLRequest(url: url, timeoutInterval: 3600)
        request.httpMethod = "PUT"
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        // Streaming from disk, so we sign with UNSIGNED-PAYLOAD (allowed over HTTPS) instead of hashing the file.
        SigV4.sign(&request, credentials: config.credentials, region: config.region, payloadHash: SigV4.unsignedPayload)

        let delegate = progress.map(UploadProgressDelegate.init)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.upload(for: request, fromFile: fileURL, delegate: delegate)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
        let http = try Self.check(response, data)
        return PutObjectResult(key: key, etag: http.value(forHTTPHeaderField: "ETag"), url: url)
    }

    public func deleteObject(key: String) async throws {
        var request = URLRequest(url: objectURL(key: key))
        request.httpMethod = "DELETE"
        SigV4.sign(&request, credentials: config.credentials, region: config.region, payloadHash: SigV4.emptyPayloadHash)
        let (data, response) = try await session.data(for: request)
        _ = try Self.check(response, data)
    }

    /// Verifies credentials and bucket access.
    public func headBucket() async throws {
        var request = URLRequest(url: bucketURL())
        request.httpMethod = "HEAD"
        SigV4.sign(&request, credentials: config.credentials, region: config.region, payloadHash: SigV4.emptyPayloadHash)
        let (data, response) = try await session.data(for: request)
        _ = try Self.check(response, data)
    }

    @discardableResult
    static func check(_ response: URLResponse, _ body: Data) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw TigrisError(statusCode: 0, code: nil, message: "Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TigrisError.from(response: http, body: body)
        }
        return http
    }
}

final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let onProgress: @Sendable (Int64, Int64) -> Void

    init(onProgress: @Sendable @escaping (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        onProgress(totalBytesSent, totalBytesExpectedToSend)
    }
}
