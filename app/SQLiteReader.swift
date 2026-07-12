// PR 10a — SQLiteReader (shared local-provider infrastructure).
//
// Read-only SQLite reader used by every local-file provider that reads a
// VS-Code-family SQLite database (Cursor, Windsurf, Cline via VS Code
// globalStorage/state.vscdb). Never opens a database read-write, never
// runs schema-mutating statements, and always emits `PRAGMA query_only=1`
// before any user query.
//
// Design goals — every constraint here is defensive, not decorative:
//
//   1. Read-only file open. `sqlite3_open_v2(SQLITE_OPEN_READONLY |
//      SQLITE_OPEN_NOMUTEX)`. NOMUTEX because every SQLiteReader instance
//      is only ever touched from a single thread (the local-provider's
//      polling closure); the app-wide serialisation is done at the store
//      layer.
//   2. `PRAGMA query_only=1`. Belt-and-braces against a future refactor
//      that accidentally passes a non-SELECT statement. Even a read-only
//      handle can be tricked into writing to a temp table without this.
//   3. `PRAGMA busy_timeout=5000`. VS Code / Cursor / Windsurf hold write
//      locks on their state.vscdb during startup and during editor state
//      persistence. Without a busy timeout, a concurrent write locks our
//      SELECTs with `SQLITE_BUSY` immediately. 5s is enough to survive
//      the ~1s writes those apps do, without hanging our fetch cadence.
//   4. Optional schema-version sentinel. Callers can register a
//      `(table, versionColumn, expected)` tuple; the reader verifies it
//      on open and refuses further queries if the schema has moved.
//      Cursor's cursor-stats maintainer archived that project citing
//      exactly this class of churn — we surface it as a distinct error.
//   5. Prepared statements are finalised on scope exit; connection is
//      closed on `deinit`. No SQL-injection concerns because every path
//      uses `?` bind placeholders — but the API only accepts prepared
//      SQL with typed binds anyway.
//   6. No mutation is possible through the public surface — the API is
//      shaped like `query(sql:binds:decoding:)` returning an array of
//      the caller's decoded row type; there is no `execute` sibling.
//
// See `SQLiteReaderTests` in the TestRunner for the 7-scenario matrix
// this file is verified against.

import Foundation
import SQLite3

/// Errors surfaced by SQLiteReader. The categories are chosen so a local
/// provider can render distinct UI states — an app that's "not opened yet"
/// (no file at path) is different from "schema drifted" (needs an app
/// update) is different from "locked by editor" (transient, retry).
public enum SQLiteReaderError: Error, Equatable {
    /// The database file does not exist at the given path. Common in
    /// dev — the target app has never been launched.
    case notFound(String)
    /// The file exists but the process cannot open it. Almost always a
    /// TCC / Full Disk Access denial; local providers should render a
    /// `.needsAccess` tile in response.
    case openFailed(rc: Int32, message: String)
    /// The file opened but isn't SQLite (SQLITE_NOTADB). VS Code's state
    /// files have been observed corrupted this way after abrupt shutdowns.
    case notADatabase
    /// The file opened but is encrypted (typical of SQLCipher databases).
    /// We won't attempt a key — surface it and skip.
    case encrypted
    /// Statement prepare or step returned an error that isn't in the
    /// known categories above.
    case sqlError(rc: Int32, message: String)
    /// The database schema doesn't match the version the caller expects.
    /// Contains both the observed and expected sentinel values for the
    /// diagnostic message.
    case schemaMismatch(observed: String, expected: String)
    /// A concurrent writer held the lock longer than the busy timeout.
    /// The caller should retry on the next poll — this is not a bug.
    case busy
}

/// A schema-version sentinel query the reader uses to detect a database
/// whose schema has drifted beyond what the caller was written against.
/// The reader runs `SELECT {valueColumn} FROM {table} WHERE {keyColumn}
/// = {key}` and compares against `expected`. Absence of the row or a
/// mismatch is reported as `.schemaMismatch`.
public struct SQLiteSchemaSentinel: Sendable, Equatable {
    public let table: String
    public let keyColumn: String
    public let key: String
    public let valueColumn: String
    public let expected: String

    public init(table: String, keyColumn: String, key: String, valueColumn: String, expected: String) {
        self.table = table
        self.keyColumn = keyColumn
        self.key = key
        self.valueColumn = valueColumn
        self.expected = expected
    }
}

/// Bind values supported by the reader. Deliberately narrow — every local
/// provider we ship needs only integers, doubles, strings, and NULL for
/// `WHERE` clauses.
public enum SQLiteBind: Sendable, Equatable {
    case int(Int64)
    case double(Double)
    case text(String)
    case null
}

/// One row produced by `query(sql:binds:)`. Columns are indexed by name;
/// the caller decodes into its own strong type.
public struct SQLiteRow: Sendable {
    fileprivate let columns: [String: SQLiteValue]

    public func int(_ column: String) -> Int64? {
        if case let .int(v) = columns[column] { return v }
        return nil
    }
    public func double(_ column: String) -> Double? {
        if case let .double(v) = columns[column] { return v }
        // Fall back to Int → Double promotion for schemas that store
        // fractional counts as integers.
        if case let .int(v) = columns[column] { return Double(v) }
        return nil
    }
    public func string(_ column: String) -> String? {
        if case let .text(v) = columns[column] { return v }
        return nil
    }
    public func blob(_ column: String) -> Data? {
        if case let .blob(v) = columns[column] { return v }
        return nil
    }
    public func isNull(_ column: String) -> Bool {
        if case .null = columns[column] { return true }
        return columns[column] == nil
    }
}

/// The internal column-value representation. Not exposed in the public
/// API — `SQLiteRow` accessors coerce out of this.
fileprivate enum SQLiteValue: Sendable {
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
    case null
}

/// A read-only, single-thread SQLite reader. See the file header for the
/// full rationale on each constraint.
///
/// Marked `final class` (not a value type) because it owns a `sqlite3*`
/// handle that must be closed exactly once on deallocation, and that
/// lifecycle is not expressible as a Sendable value.
public final class SQLiteReader {

    private let db: OpaquePointer
    private let path: String
    /// True after `close()` — subsequent queries throw `sqlError` rather
    /// than passing a nil handle to sqlite3.
    private var closed = false

    /// Open a database in strict read-only mode with a 5-second busy
    /// timeout and `query_only` enforced. If a `sentinel` is supplied,
    /// the reader validates it on open and throws `.schemaMismatch` if
    /// the observed value differs.
    ///
    /// Throws:
    ///   - `.notFound` if the file does not exist.
    ///   - `.openFailed` if sqlite3 rejected the open call (typically TCC).
    ///   - `.notADatabase` if the header check fails.
    ///   - `.encrypted` if the header check reveals SQLCipher.
    ///   - `.schemaMismatch` if the sentinel does not match.
    ///   - `.sqlError` for other prepare/step failures during init.
    public init(path: String, sentinel: SQLiteSchemaSentinel? = nil) throws {
        // Existence pre-check — sqlite3_open_v2(READONLY) refuses to create
        // a database, but its error code (SQLITE_CANTOPEN) collapses
        // "not found" and "permission denied" into one signal. Split them
        // here so a `.notFound` tile ("app not installed") is distinct
        // from a `.needsAccess` tile ("Full Disk Access denied").
        if !FileManager.default.fileExists(atPath: path) {
            throw SQLiteReaderError.notFound(path)
        }
        // Encryption / not-a-DB pre-check via the first 16 bytes of the
        // file. SQLite databases start with the literal 16-byte header
        // "SQLite format 3\0"; SQLCipher databases have random-looking
        // bytes because the header itself is encrypted. This gives us a
        // clean, actionable error before sqlite3_open_v2 emits its more
        // generic "file is not a database" message.
        if let handle = FileHandle(forReadingAtPath: path) {
            defer { try? handle.close() }
            let head = handle.readData(ofLength: 16)
            let expected = "SQLite format 3\u{0}".data(using: .ascii) ?? Data()
            if head.count == 16 && head != expected {
                // Not the SQLite magic. Distinguish encrypted (random-
                // looking full 16 bytes) from an empty / truncated file.
                if head.count == 16 {
                    // If the whole 16-byte block is non-ASCII-printable
                    // it's almost certainly an encrypted database. This
                    // heuristic is intentionally loose — the tests
                    // include an SQLCipher fixture that exercises it.
                    let nonPrintable = head.filter { $0 < 0x20 || $0 > 0x7E }.count
                    if nonPrintable >= 12 {
                        throw SQLiteReaderError.encrypted
                    }
                }
                throw SQLiteReaderError.notADatabase
            }
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let db = handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let db = handle { sqlite3_close(db) }
            throw SQLiteReaderError.openFailed(rc: rc, message: msg)
        }
        self.db = db
        self.path = path

        // PRAGMA setup: enforce query-only, arm the busy timeout, and
        // reject any pragma failure loudly rather than silently
        // proceeding without the protections.
        do {
            try Self.pragma(db: db, "PRAGMA query_only=1")
            try Self.pragma(db: db, "PRAGMA busy_timeout=5000")
        } catch {
            sqlite3_close(db)
            throw error
        }

        // Schema sentinel validation — do this INSIDE init so the caller
        // can't miss it. If the DB schema drifted, the reader is dead on
        // arrival and no query() call needs to guard against it.
        if let sentinel = sentinel {
            do {
                try validateSchemaSentinel(sentinel)
            } catch {
                sqlite3_close(db)
                throw error
            }
        }
    }

    deinit {
        if !closed {
            sqlite3_close(db)
        }
    }

    /// Close the database explicitly. Safe to call more than once. After
    /// close(), further query() calls throw `.sqlError`. Callers usually
    /// don't need to call this — deinit handles it — but it's exposed so
    /// tests can deterministically release file handles before deleting
    /// the fixture directory.
    public func close() {
        if closed { return }
        sqlite3_close(db)
        closed = true
    }

    /// Run a SELECT statement and decode every row via the caller's
    /// closure. The statement is finalised on return. `binds` map to
    /// numbered `?` placeholders 1-indexed on the wire (but here as
    /// natural 0-indexed swift array positions).
    public func query<T>(
        _ sql: String,
        binds: [SQLiteBind] = [],
        decode: (SQLiteRow) -> T?
    ) throws -> [T] {
        if closed {
            throw SQLiteReaderError.sqlError(rc: SQLITE_MISUSE, message: "reader is closed")
        }
        var stmt: OpaquePointer?
        let prepareRc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepareRc == SQLITE_OK, let handle = stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            if let s = stmt { sqlite3_finalize(s) }
            throw SQLiteReaderError.sqlError(rc: prepareRc, message: msg)
        }
        defer { sqlite3_finalize(handle) }

        for (idx, bind) in binds.enumerated() {
            try Self.bind(stmt: handle, index: Int32(idx + 1), value: bind, db: db)
        }

        var out: [T] = []
        while true {
            let rc = sqlite3_step(handle)
            if rc == SQLITE_DONE { break }
            if rc == SQLITE_BUSY { throw SQLiteReaderError.busy }
            if rc != SQLITE_ROW {
                throw SQLiteReaderError.sqlError(rc: rc, message: String(cString: sqlite3_errmsg(db)))
            }
            let row = try Self.decodeRow(stmt: handle)
            if let decoded = decode(row) {
                out.append(decoded)
            }
        }
        return out
    }

    // MARK: - Internals

    private func validateSchemaSentinel(_ sentinel: SQLiteSchemaSentinel) throws {
        // Codex round-1 finding #7: sentinel identifiers are interpolated
        // into SQL, so we validate them strictly first. SQL identifiers
        // in every schema we care about (VS Code state.vscdb, Cursor,
        // Windsurf, Warp, Cline, JetBrains, Continue) are lowercase
        // ASCII letters, digits, and underscores only — anything else
        // is a config bug in the caller. Reject early so a maintainer
        // typo cannot silently produce a corrupt SQL statement.
        for identifier in [sentinel.table, sentinel.keyColumn, sentinel.valueColumn] {
            try Self.assertIsValidIdentifier(identifier)
        }
        let sql = "SELECT \(sentinel.valueColumn) FROM \(sentinel.table) WHERE \(sentinel.keyColumn) = ?"
        let rows = try query(sql, binds: [.text(sentinel.key)]) { row in
            row.string(sentinel.valueColumn)
        }
        guard let observed = rows.first else {
            throw SQLiteReaderError.schemaMismatch(observed: "<row missing>", expected: sentinel.expected)
        }
        if observed != sentinel.expected {
            throw SQLiteReaderError.schemaMismatch(observed: observed, expected: sentinel.expected)
        }
    }

    /// Reject identifiers that would produce hostile SQL when
    /// interpolated. Strict ASCII contract per Codex round-2 nit:
    /// `[A-Za-z_][A-Za-z0-9_]{0,63}`. Every schema we care about (VS
    /// Code state.vscdb, Cursor, Windsurf, Warp, Cline, JetBrains,
    /// Continue) uses ASCII-only identifiers; non-ASCII input is a
    /// caller bug, not a supported edge case. Public so downstream
    /// local-provider PRs can reuse it wherever they build SQL from
    /// config or metadata.
    public static func assertIsValidIdentifier(_ name: String) throws {
        guard !name.isEmpty, name.count <= 64 else {
            throw SQLiteReaderError.sqlError(rc: SQLITE_MISUSE, message: "invalid SQL identifier: \(name.prefix(32))")
        }
        let bytes = Array(name.utf8)
        // First byte: strict ASCII letter or underscore.
        let firstOK = Self.isAsciiLetter(bytes[0]) || bytes[0] == UInt8(ascii: "_")
        if !firstOK {
            throw SQLiteReaderError.sqlError(rc: SQLITE_MISUSE, message: "invalid SQL identifier: \(name.prefix(32))")
        }
        for i in 1 ..< bytes.count {
            let b = bytes[i]
            let ok = Self.isAsciiLetter(b) || Self.isAsciiDigit(b) || b == UInt8(ascii: "_")
            if !ok {
                throw SQLiteReaderError.sqlError(rc: SQLITE_MISUSE, message: "invalid SQL identifier: \(name.prefix(32))")
            }
        }
    }

    @inline(__always)
    private static func isAsciiLetter(_ b: UInt8) -> Bool {
        (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z")) ||
        (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z"))
    }
    @inline(__always)
    private static func isAsciiDigit(_ b: UInt8) -> Bool {
        b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9")
    }

    private static func pragma(db: OpaquePointer, _ sql: String) throws {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let handle = stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            if let s = stmt { sqlite3_finalize(s) }
            throw SQLiteReaderError.sqlError(rc: rc, message: msg)
        }
        defer { sqlite3_finalize(handle) }
        let step = sqlite3_step(handle)
        guard step == SQLITE_DONE || step == SQLITE_ROW else {
            throw SQLiteReaderError.sqlError(rc: step, message: String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Sentinel object required by sqlite3 to mark a bind as a transient
    /// pointer (i.e. sqlite must copy it) rather than a static pointer.
    /// See sqlite.org/c3ref/c_static.html — using the wrong sentinel is
    /// a classic use-after-free class of bug.
    private static let SQLITE_TRANSIENT = unsafeBitCast(
        OpaquePointer(bitPattern: -1),
        to: sqlite3_destructor_type.self
    )

    private static func bind(stmt: OpaquePointer, index: Int32, value: SQLiteBind, db: OpaquePointer) throws {
        let rc: Int32
        switch value {
        case .int(let v):
            rc = sqlite3_bind_int64(stmt, index, v)
        case .double(let v):
            rc = sqlite3_bind_double(stmt, index, v)
        case .text(let s):
            rc = s.withCString { cstr in
                sqlite3_bind_text(stmt, index, cstr, -1, SQLITE_TRANSIENT)
            }
        case .null:
            rc = sqlite3_bind_null(stmt, index)
        }
        guard rc == SQLITE_OK else {
            throw SQLiteReaderError.sqlError(rc: rc, message: String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func decodeRow(stmt: OpaquePointer) throws -> SQLiteRow {
        let count = sqlite3_column_count(stmt)
        var columns: [String: SQLiteValue] = [:]
        columns.reserveCapacity(Int(count))
        for i in 0 ..< count {
            let name = String(cString: sqlite3_column_name(stmt, i))
            let value: SQLiteValue
            switch sqlite3_column_type(stmt, i) {
            case SQLITE_INTEGER:
                value = .int(sqlite3_column_int64(stmt, i))
            case SQLITE_FLOAT:
                value = .double(sqlite3_column_double(stmt, i))
            case SQLITE_TEXT:
                if let cstr = sqlite3_column_text(stmt, i) {
                    value = .text(String(cString: cstr))
                } else {
                    value = .null
                }
            case SQLITE_BLOB:
                let bytes = sqlite3_column_bytes(stmt, i)
                if bytes > 0, let ptr = sqlite3_column_blob(stmt, i) {
                    value = .blob(Data(bytes: ptr, count: Int(bytes)))
                } else {
                    value = .null
                }
            case SQLITE_NULL:
                value = .null
            default:
                value = .null
            }
            columns[name] = value
        }
        return SQLiteRow(columns: columns)
    }
}
