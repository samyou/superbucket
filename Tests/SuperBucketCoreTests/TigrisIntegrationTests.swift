import XCTest
@testable import SuperBucketCore

/// Runs only when TIGRIS_STORAGE_ACCESS_KEY_ID, TIGRIS_STORAGE_SECRET_ACCESS_KEY and TIGRIS_STORAGE_BUCKET are set.
final class TigrisIntegrationTests: XCTestCase {
    func makeClient() throws -> TigrisClient {
        let env = ProcessInfo.processInfo.environment
        guard let id = env["TIGRIS_STORAGE_ACCESS_KEY_ID"],
              let secret = env["TIGRIS_STORAGE_SECRET_ACCESS_KEY"],
              let bucket = env["TIGRIS_STORAGE_BUCKET"] ?? env["TIGRIS_BUCKET"] else {
            throw XCTSkip("Tigris credentials not set")
        }
        return TigrisClient(config: TigrisConfig(bucket: bucket, credentials: AWSCredentials(accessKeyID: id, secretAccessKey: secret)))
    }

    func testHeadBucket() async throws {
        try await makeClient().headBucket()
    }

    func testUploadPresignDownloadDelete() async throws {
        let client = try makeClient()
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("superbucket-\(UUID().uuidString).bin")
        try payload.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let key = "superbucket-tests/dir with space/파일 \(UUID().uuidString).bin"
        let progress = ProgressBox()
        let result = try await client.putObject(fileURL: tmp, key: key, contentType: "application/octet-stream") { sent, _ in
            progress.record(sent)
        }
        XCTAssertEqual(result.key, key)
        XCTAssertEqual(progress.max, Int64(payload.count))

        let (downloaded, response) = try await URLSession.shared.data(from: client.presignedGetURL(key: key, expires: 120))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(downloaded, payload)

        try await client.deleteObject(key: key)
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0
    var max: Int64 { lock.withLock { value } }
    func record(_ sent: Int64) { lock.withLock { value = Swift.max(value, sent) } }
}

final class MultipartIntegrationTests: XCTestCase {
    func testMultipartRoundTripAndHead() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let id = env["TIGRIS_STORAGE_ACCESS_KEY_ID"], let secret = env["TIGRIS_STORAGE_SECRET_ACCESS_KEY"],
              let bucket = env["TIGRIS_STORAGE_BUCKET"] else { throw XCTSkip("Tigris credentials not set") }
        let client = TigrisClient(config: TigrisConfig(bucket: bucket, credentials: AWSCredentials(accessKeyID: id, secretAccessKey: secret)))

        // 11 MiB with 5 MiB parts => 3 parts (5, 5, 1).
        var payload = Data(count: 11 * 1024 * 1024)
        payload.withUnsafeMutableBytes { buf in
            for i in stride(from: 0, to: buf.count, by: 4096) { buf[i] = UInt8(i / 4096 % 256) }
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("superbucket-mp-\(UUID().uuidString).bin")
        try payload.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let key = "superbucket-tests/multipart \(UUID().uuidString).bin"

        let head0 = try await client.headObject(key: key)
        XCTAssertNil(head0)

        let progress = ProgressBox()
        let result = try await client.uploadFile(
            fileURL: tmp, key: key, contentType: "application/octet-stream",
            multipartThreshold: 1, options: MultipartOptions(partSize: 5 * 1024 * 1024, maxConcurrentParts: 2)
        ) { sent, _ in progress.record(sent) }
        XCTAssertEqual(progress.max, Int64(payload.count))
        XCTAssertNotNil(result.etag)

        let info = try await client.headObject(key: key)
        XCTAssertEqual(info?.size, Int64(payload.count))

        let (downloaded, _) = try await URLSession.shared.data(from: client.presignedGetURL(key: key, expires: 120))
        XCTAssertEqual(downloaded, payload)
        try await client.deleteObject(key: key)
        let head1 = try await client.headObject(key: key)
        XCTAssertNil(head1)
    }

    func testMultipartCancelAborts() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let id = env["TIGRIS_STORAGE_ACCESS_KEY_ID"], let secret = env["TIGRIS_STORAGE_SECRET_ACCESS_KEY"],
              let bucket = env["TIGRIS_STORAGE_BUCKET"] else { throw XCTSkip("Tigris credentials not set") }
        let client = TigrisClient(config: TigrisConfig(bucket: bucket, credentials: AWSCredentials(accessKeyID: id, secretAccessKey: secret)))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("superbucket-mp-cancel-\(UUID().uuidString).bin")
        try Data(count: 16 * 1024 * 1024).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let key = "superbucket-tests/cancel \(UUID().uuidString).bin"

        let task = Task {
            try await client.multipartUpload(fileURL: tmp, key: key, options: MultipartOptions(partSize: 5 * 1024 * 1024, maxConcurrentParts: 1))
        }
        try await Task.sleep(nanoseconds: 700_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected error \(error)")
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        let head2 = try await client.headObject(key: key)
        XCTAssertNil(head2)
    }
}
