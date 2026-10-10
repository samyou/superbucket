import XCTest

/// Mirrors AppSettings.cleanCredential (the app target can't be imported by tests).
final class CredentialCleaningTests: XCTestCase {
    func clean(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let eq = s.lastIndex(of: "=") { s = String(s[s.index(after: eq)...]) }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t\n\r"))
    }

    func testCleaning() {
        XCTAssertEqual(clean("  tsec_abc \n"), "tsec_abc")
        XCTAssertEqual(clean("TIGRIS_STORAGE_SECRET_ACCESS_KEY=tsec_abc"), "tsec_abc")
        XCTAssertEqual(clean("TIGRIS_STORAGE_SECRET_ACCESS_KEY=\"tsec_abc\""), "tsec_abc")
        XCTAssertEqual(clean("tsec_abc"), "tsec_abc")
    }
}
