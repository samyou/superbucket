import XCTest
@testable import SuperBucketCore

final class SigV4Tests: XCTestCase {
    /// "get-vanilla" vector from the AWS SigV4 test suite.
    func testGetVanillaVector() {
        let creds = AWSCredentials(accessKeyID: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
        var request = URLRequest(url: URL(string: "https://example.amazonaws.com/")!)
        request.httpMethod = "GET"
        let date = ISO8601DateFormatter().date(from: "2015-08-30T12:36:00Z")!
        SigV4.sign(&request, credentials: creds, region: "us-east-1", service: "service",
                   payloadHash: SigV4.emptyPayloadHash, date: date)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"
        )
    }

    func testEncodingRules() {
        XCTAssertEqual(SigV4.encode("a b/c~d.txt", allowSlash: true), "a%20b/c~d.txt")
        XCTAssertEqual(SigV4.encode("a b/c"), "a%20b%2Fc")
        XCTAssertEqual(SigV4.encode("한글.png"), "%ED%95%9C%EA%B8%80.png")
    }

    func testObjectURLStyles() {
        let creds = AWSCredentials(accessKeyID: "k", secretAccessKey: "s")
        let virtual = TigrisClient(config: TigrisConfig(bucket: "my-bucket", credentials: creds))
        XCTAssertEqual(virtual.objectURL(key: "dir/my file.txt").absoluteString,
                       "https://my-bucket.t3.storage.dev/dir/my%20file.txt")
        let path = TigrisClient(config: TigrisConfig(bucket: "my-bucket", pathStyle: true, credentials: creds))
        XCTAssertEqual(path.objectURL(key: "dir/my file.txt").absoluteString,
                       "https://t3.storage.dev/my-bucket/dir/my%20file.txt")
    }

    func testPresignHasRequiredParams() {
        let creds = AWSCredentials(accessKeyID: "k", secretAccessKey: "s")
        let client = TigrisClient(config: TigrisConfig(bucket: "b", credentials: creds))
        let url = client.presignedGetURL(key: "x.txt", expires: 60)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let names = Set(items.map(\.name))
        XCTAssertTrue(names.isSuperset(of: ["X-Amz-Algorithm", "X-Amz-Credential", "X-Amz-Date", "X-Amz-Expires", "X-Amz-SignedHeaders", "X-Amz-Signature"]))
        XCTAssertEqual(items.first { $0.name == "X-Amz-Expires" }?.value, "60")
    }
}
