import Foundation
import SQLite3

/// An OAuth credential row read from oh-my-pi's agent database.
struct OmpOAuthCredential: Equatable {
    let accessToken: String
    let accountId: String?
    let expiresAt: Date?

    func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt < now
    }
}

/// Read-only access to oh-my-pi's credential store
/// (~/.omp/agent/agent.db, table auth_credentials). omp keeps its own
/// OAuth tokens for the same Claude / ChatGPT accounts the CLIs use, and
/// refreshes them on use — so it is a natural fallback source when the
/// Claude Code / Codex CLI tokens have expired unused.
///
/// Posture matches the other credential sources: tokmon never refreshes
/// or writes tokens, and never reads the refresh token. The schema is
/// omp-internal and may drift, so every failure (missing file, busy WAL
/// checkpoint, schema change, malformed JSON) degrades to nil — omp is
/// an optional source, never an error surfaced to the UI.
///
/// The db is WAL-mode; a read-only connection still needs to map the
/// user-owned `-shm` file, which the read-only open handles. SQLITE_BUSY
/// simply means "no credential this poll".
enum OmpCredentialStore {
    static var defaultDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".omp/agent/agent.db")
    }

    /// omp provider identifiers, e.g. "anthropic" or "openai-codex".
    static func credential(
        provider: String,
        databaseURL: URL = defaultDatabaseURL
    ) -> OmpOAuthCredential? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database
        else {
            // sqlite3_open_v2 may allocate a handle even on failure.
            sqlite3_close_v2(database)
            return nil
        }
        defer { sqlite3_close_v2(database) }

        let sql = """
        SELECT data FROM auth_credentials
        WHERE provider = ?1 AND credential_type = 'oauth' AND disabled_cause IS NULL
        ORDER BY updated_at DESC LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, provider, -1, transient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0)
        else {
            return nil
        }
        return decodeCredential(json: String(cString: text))
    }

    /// The `data` column payload. Only the fields tokmon needs are read;
    /// the refresh token is deliberately not decoded.
    private struct RowData: Decodable {
        let access: String?
        let accountId: String?
        let expires: Double?  // milliseconds since epoch
    }

    static func decodeCredential(json: String) -> OmpOAuthCredential? {
        guard let data = json.data(using: .utf8),
              let row = try? JSONDecoder().decode(RowData.self, from: data),
              let access = row.access, !access.isEmpty
        else {
            return nil
        }
        return OmpOAuthCredential(
            accessToken: access,
            accountId: row.accountId,
            expiresAt: row.expires.map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }
}
