import Foundation

public struct ObjectInfo: Sendable, Equatable {
    public var key: String
    public var size: Int64
    public var etag: String?
}

/// Tuning for multipart uploads. S3 requires parts of at least 5 MiB (except the last) and at most 10,000 parts.
public struct MultipartOptions: Sendable {
    public var partSize: Int
    public var maxConcurrentParts: Int
    public var retriesPerPart: Int

    public static let minimumPartSize = 5 * 1024 * 1024

    public init(partSize: Int = 32 * 1024 * 1024, maxConcurrentParts: Int = 4, retriesPerPart: Int = 3) {
        self.partSize = max(partSize, Self.minimumPartSize)
        self.maxConcurrentParts = max(1, maxConcurrentParts)
        self.retriesPerPart = max(0, retriesPerPart)
    }
}

extension TigrisClient {
    /// Default size above which `uploadFile` switches from a single PUT to multipart.
    public static let multipartThreshold: Int64 = 64 * 1024 * 1024

    func url(key: String, query: [(String, String?)]) -> URL {
        var components = URLComponents(url: objectURL(key: key), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = query.map { name, value in
            value.map { "\(SigV4.encode(name))=\(SigV4.encode($0))" } ?? SigV4.encode(name)
        }.joined(separator: "&")
        return components.url!
    }

    // MARK: Head

    /// Returns `nil` when the object does not exist.
    public func headObject(key: String) async throws -> ObjectInfo? {
        var request = URLRequest(url: objectURL(key: key))
        request.httpMethod = "HEAD"
        SigV4.sign(&request, credentials: config.credentials, region: config.region, payloadHash: SigV4.emptyPayloadHash)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TigrisError(statusCode: 0, code: nil, message: "Non-HTTP response") }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw TigrisError(statusCode: http.statusCode, code: http.statusCode == 403 ? "AccessDenied" : nil, message: nil)
        }
        let length = Int64(http.value(forHTTPHeaderField: "Content-Length") ?? "") ?? -1
        return ObjectInfo(key: key, size: length, etag: http.value(forHTTPHeaderField: "ETag"))
    }

    // MARK: Upload entry point

    /// Uploads a file, choosing a single PUT or multipart based on size.
    public func uploadFile(
        fileURL: URL,
        key: String,
        contentType: String? = nil,
        multipartThreshold: Int64 = TigrisClient.multipartThreshold,
        options: MultipartOptions = MultipartOptions(),
        progress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> PutObjectResult {
        let size = Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        if size >= multipartThreshold {
            return try await multipartUpload(fileURL: fileURL, key: key, contentType: contentType, options: options, progress: progress)
        }
        return try await putObject(fileURL: fileURL, key: key, contentType: contentType, progress: progress)
    }

    // MARK: Multipart

    public func multipartUpload(
        fileURL: URL,
        key: String,
        contentType: String? = nil,
        options: MultipartOptions = MultipartOptions(),
        progress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> PutObjectResult {
        let totalSize = Int64((try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let partCount = max(1, Int((totalSize + Int64(options.partSize) - 1) / Int64(options.partSize)))
        guard partCount <= 10_000 else {
            throw TigrisError(statusCode: 0, code: "TooManyParts", message: "Increase the part size for a file this large.")
        }

        let uploadId: String
        do {
            uploadId = try await createMultipartUpload(key: key, contentType: contentType)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
        let tracker = ProgressTracker(total: totalSize, report: progress)

        do {
            let etags = try await withThrowingTaskGroup(of: (Int, String).self, returning: [Int: String].self) { group in
                var results: [Int: String] = [:]
                var next = 1
                func enqueue() {
                    let partNumber = next
                    next += 1
                    let offset = Int64(partNumber - 1) * Int64(options.partSize)
                    let length = Int(min(Int64(options.partSize), totalSize - offset))
                    group.addTask {
                        try await self.uploadPartWithRetry(
                            fileURL: fileURL, key: key, uploadId: uploadId, partNumber: partNumber,
                            offset: offset, length: length, options: options, tracker: tracker
                        )
                    }
                }
                while next <= partCount && next <= options.maxConcurrentParts { enqueue() }
                while let (partNumber, etag) = try await group.next() {
                    results[partNumber] = etag
                    if next <= partCount { enqueue() }
                }
                return results
            }
            let ordered = (1...partCount).map { (partNumber: $0, etag: etags[$0] ?? "") }
            let etag = try await completeMultipartUpload(key: key, uploadId: uploadId, parts: ordered)
            tracker.finish()
            return PutObjectResult(key: key, etag: etag, url: objectURL(key: key))
        } catch {
            // Abort even if we were cancelled, so Tigris does not keep orphaned parts around.
            await Task.detached { try? await self.abortMultipartUpload(key: key, uploadId: uploadId) }.value
            if let urlError = error as? URLError, urlError.code == .cancelled { throw CancellationError() }
            throw error
        }
    }

    private func uploadPartWithRetry(
        fileURL: URL, key: String, uploadId: String, partNumber: Int,
        offset: Int64, length: Int, options: MultipartOptions, tracker: ProgressTracker
    ) async throws -> (Int, String) {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let data = try Self.readChunk(fileURL: fileURL, offset: offset, length: length)
                let etag = try await uploadPart(key: key, uploadId: uploadId, partNumber: partNumber, data: data, tracker: tracker)
                tracker.complete(part: partNumber, bytes: Int64(length))
                return (partNumber, etag)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error as TigrisError where (400..<500).contains(error.statusCode) {
                throw error // client errors won't succeed on retry
            } catch {
                attempt += 1
                tracker.reset(part: partNumber)
                guard attempt <= options.retriesPerPart else { throw error }
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            }
        }
    }

    private static func readChunk(fileURL: URL, offset: Int64, length: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: length) ?? Data()
    }

    private func createMultipartUpload(key: String, contentType: String?) async throws -> String {
        var request = URLRequest(url: url(key: key, query: [("uploads", nil)]))
        request.httpMethod = "POST"
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        SigV4.sign(&request, credentials: config.credentials, region: config.region, payloadHash: SigV4.emptyPayloadHash)
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data)
        guard let uploadId = Self.xmlValue("UploadId", in: data) else {
            throw TigrisError(statusCode: 0, code: "BadResponse", message: "No UploadId in CreateMultipartUpload response")
        }
        return uploadId
    }

    private func uploadPart(key: String, uploadId: String, partNumber: Int, data: Data, tracker: ProgressTracker) async throws -> String {
        var request = URLRequest(
            url: url(key: key, query: [("partNumber", String(partNumber)), ("uploadId", uploadId)]),
            timeoutInterval: 3600
        )
        request.httpMethod = "PUT"
        SigV4.sign(&request, credentials: config.credentials, region: config.region, payloadHash: SigV4.unsignedPayload)
        let delegate = UploadProgressDelegate { sent, _ in tracker.update(part: partNumber, sent: sent) }
        let (body, response) = try await session.upload(for: request, from: data, delegate: delegate)
        let http = try Self.check(response, body)
        guard let etag = http.value(forHTTPHeaderField: "ETag") else {
            throw TigrisError(statusCode: http.statusCode, code: "BadResponse", message: "No ETag in UploadPart response")
        }
        return etag
    }

    private func completeMultipartUpload(key: String, uploadId: String, parts: [(partNumber: Int, etag: String)]) async throws -> String? {
        var xml = "<CompleteMultipartUpload>"
        for part in parts {
            let etag = part.etag.replacingOccurrences(of: "\"", with: "&quot;")
            xml += "<Part><PartNumber>\(part.partNumber)</PartNumber><ETag>\(etag)</ETag></Part>"
        }
        xml += "</CompleteMultipartUpload>"
        let body = Data(xml.utf8)

        var request = URLRequest(url: url(key: key, query: [("uploadId", uploadId)]), timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        SigV4.sign(&request, credentials: config.credentials, region: config.region, payloadHash: SigV4.hexSHA256(body))
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data)
        // S3 can return 200 with an <Error> body for Complete.
        if Self.xmlValue("Error", in: data) != nil, let code = Self.xmlValue("Code", in: data) {
            throw TigrisError(statusCode: 200, code: code, message: Self.xmlValue("Message", in: data))
        }
        return Self.xmlValue("ETag", in: data)?.replacingOccurrences(of: "&quot;", with: "\"")
    }

    private func abortMultipartUpload(key: String, uploadId: String) async throws {
        var request = URLRequest(url: url(key: key, query: [("uploadId", uploadId)]))
        request.httpMethod = "DELETE"
        SigV4.sign(&request, credentials: config.credentials, region: config.region, payloadHash: SigV4.emptyPayloadHash)
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data)
    }

    static func xmlValue(_ tag: String, in data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        guard let open = text.range(of: "<\(tag)>"), let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[open.upperBound..<close.lowerBound])
    }
}

/// Aggregates per-part progress into one (sent, total) callback.
final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight: [Int: Int64] = [:]
    private var completed: Int64 = 0
    private let total: Int64
    private let report: (@Sendable (Int64, Int64) -> Void)?

    init(total: Int64, report: (@Sendable (Int64, Int64) -> Void)?) {
        self.total = total
        self.report = report
    }

    func update(part: Int, sent: Int64) {
        lock.withLock { inFlight[part] = sent }
        emit()
    }

    func reset(part: Int) {
        lock.withLock { inFlight[part] = 0 }
        emit()
    }

    func complete(part: Int, bytes: Int64) {
        lock.withLock { inFlight[part] = nil; completed += bytes }
        emit()
    }

    func finish() {
        report?(total, total)
    }

    private func emit() {
        let sent = lock.withLock { completed + inFlight.values.reduce(0, +) }
        report?(min(sent, total), total)
    }
}
