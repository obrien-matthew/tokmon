import Foundation
import SQLite3
import XCTest
@testable import tokmon

final class OmpCredentialStoreTests: XCTestCase {
    private var databaseURL: URL!

    override func setUpWithError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokmon-omp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("agent.db")
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent())
    }

    // MARK: - Fixture

    private struct FixtureRow {
        let provider: String
        let data: String
        var disabled: String?
        var updatedAt: Int = 10
    }

    /// Builds the fixture in WAL mode so the read-only open exercises the
    /// same journal mode as omp's real database.
    private func createDatabase(rows: [FixtureRow]) throws {
        var database: OpaquePointer?
        defer { sqlite3_close_v2(database) }
        guard sqlite3_open_v2(
            databaseURL.path, &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil
        ) == SQLITE_OK, let database else {
            throw XCTSkip("Cannot create fixture database")
        }
        try exec(database, "PRAGMA journal_mode=WAL")
        try exec(database, """
        CREATE TABLE auth_credentials (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            provider TEXT NOT NULL,
            credential_type TEXT NOT NULL,
            data TEXT NOT NULL,
            disabled_cause TEXT DEFAULT NULL,
            identity_key TEXT DEFAULT NULL,
            created_at INTEGER NOT NULL DEFAULT 0,
            updated_at INTEGER NOT NULL DEFAULT 0
        )
        """)
        for row in rows {
            let disabled = row.disabled.map { "'\($0)'" } ?? "NULL"
            try exec(database, """
            INSERT INTO auth_credentials (provider, credential_type, data, disabled_cause, updated_at)
            VALUES ('\(row.provider)', 'oauth', '\(row.data)', \(disabled), \(row.updatedAt))
            """)
        }
    }

    private func exec(_ database: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(message)
            XCTFail("SQL failed: \(detail)")
            throw XCTSkip("Fixture setup failed")
        }
    }

    private func payload(access: String = "sk-test", accountId: String? = "acct-1", expires: Double? = nil) -> String {
        var fields = ["\"access\":\"\(access)\""]
        if let accountId { fields.append("\"accountId\":\"\(accountId)\"") }
        if let expires { fields.append("\"expires\":\(expires)") }
        return "{\(fields.joined(separator: ","))}"
    }

    // MARK: - Tests

    func testReadsValidRow() throws {
        let expires = Date(timeIntervalSince1970: 2_000_000_000)
        try createDatabase(rows: [
            FixtureRow(provider: "anthropic", data: payload(access: "sk-live", expires: expires.timeIntervalSince1970 * 1000))
        ])
        let credential = OmpCredentialStore.credential(provider: "anthropic", databaseURL: databaseURL)
        XCTAssertEqual(credential?.accessToken, "sk-live")
        XCTAssertEqual(credential?.accountId, "acct-1")
        XCTAssertEqual(credential?.expiresAt, expires)
    }

    func testExpiryInterpretsMilliseconds() throws {
        let past = Date().addingTimeInterval(-60)
        let future = Date().addingTimeInterval(3600)
        let expired = OmpOAuthCredential(
            accessToken: "t", accountId: nil,
            expiresAt: past
        )
        let fresh = OmpOAuthCredential(accessToken: "t", accountId: nil, expiresAt: future)
        let unbounded = OmpOAuthCredential(accessToken: "t", accountId: nil, expiresAt: nil)
        XCTAssertTrue(expired.isExpired())
        XCTAssertFalse(fresh.isExpired())
        XCTAssertFalse(unbounded.isExpired())

        // ms decode: an epoch-ms payload must not be read as seconds.
        let decoded = OmpCredentialStore.decodeCredential(
            json: payload(expires: 1_786_710_254_000)
        )
        XCTAssertEqual(
            decoded?.expiresAt?.timeIntervalSince1970 ?? 0,
            1_786_710_254,
            accuracy: 1
        )
    }

    func testMissingRowReturnsNil() throws {
        try createDatabase(rows: [FixtureRow(provider: "openai-codex", data: payload())])
        XCTAssertNil(OmpCredentialStore.credential(provider: "anthropic", databaseURL: databaseURL))
    }

    func testDisabledRowIsIgnored() throws {
        try createDatabase(rows: [FixtureRow(provider: "anthropic", data: payload(), disabled: "revoked")])
        XCTAssertNil(OmpCredentialStore.credential(provider: "anthropic", databaseURL: databaseURL))
    }

    func testNewestRowWins() throws {
        try createDatabase(rows: [
            FixtureRow(provider: "anthropic", data: payload(access: "sk-old"), updatedAt: 10),
            FixtureRow(provider: "anthropic", data: payload(access: "sk-new"), updatedAt: 20)
        ])
        let credential = OmpCredentialStore.credential(provider: "anthropic", databaseURL: databaseURL)
        XCTAssertEqual(credential?.accessToken, "sk-new")
    }

    func testMalformedJSONReturnsNil() throws {
        try createDatabase(rows: [FixtureRow(provider: "anthropic", data: "not json")])
        XCTAssertNil(OmpCredentialStore.credential(provider: "anthropic", databaseURL: databaseURL))
    }

    func testEmptyAccessTokenReturnsNil() {
        XCTAssertNil(OmpCredentialStore.decodeCredential(json: #"{"access":""}"#))
        XCTAssertNil(OmpCredentialStore.decodeCredential(json: #"{"accountId":"a"}"#))
    }

    func testMissingFileReturnsNil() {
        let absent = databaseURL.deletingLastPathComponent().appendingPathComponent("absent.db")
        XCTAssertNil(OmpCredentialStore.credential(provider: "anthropic", databaseURL: absent))
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path), "read-only open must not create the file")
    }
}
