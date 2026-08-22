import Foundation
import SQLite3

// `SQLITE_TRANSIENT` is a C macro — `((sqlite3_destructor_type)-1)` — and does
// not import into Swift. Declared here rather than in an actor or `main.swift`,
// where top-level declarations are implicitly `@MainActor` and become
// unreachable from a nonisolated context.
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
let SQLITE_STATIC = unsafeBitCast(0, to: sqlite3_destructor_type.self)

/// The smallest SQLite wrapper that does the job.
///
/// No SPM dependency is needed: the macOS SDK ships a Clang module map for
/// system SQLite with `link "sqlite3"` in it, so `import SQLite3` both compiles
/// and auto-links `/usr/lib/libsqlite3.dylib`. That dylib is 3.51 on macOS 26
/// and 3.43 on macOS 14, and both have FTS5 with `snippet()` and `bm25()`.
///
/// The system build is `SQLITE_THREADSAFE=2` ("multi-thread"), which means one
/// connection may not be used from two threads at once — hence
/// `SQLITE_OPEN_NOMUTEX` plus confinement to an actor.
final class SQLiteDatabase: @unchecked Sendable {

    struct Error: LocalizedError {
        let code: Int32
        let message: String
        let sql: String?

        var errorDescription: String? {
            sql.map { "SQLite error \(code): \(message) — while running: \($0)" }
                ?? "SQLite error \(code): \(message)"
        }
    }

    private var handle: OpaquePointer?

    init(path: String, readOnly: Bool = false) throws {
        var flags = readOnly
            ? SQLITE_OPEN_READONLY
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        flags |= SQLITE_OPEN_NOMUTEX
        let code = sqlite3_open_v2(path, &handle, flags, nil)
        guard code == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close_v2(handle)
            handle = nil
            throw Error(code: code, message: message, sql: nil)
        }
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit { sqlite3_close_v2(handle) }

    private func fail(_ code: Int32, _ sql: String?) -> Error {
        Error(code: code,
              message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown",
              sql: sql)
    }

    /// Run one or more statements with no results and no parameters.
    func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard code == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(errorMessage)
            throw Error(code: code, message: message, sql: sql)
        }
    }

    /// A prepared statement. Bindings are 1-based, columns 0-based, matching
    /// the C API rather than inventing a second convention.
    final class Statement {
        fileprivate var pointer: OpaquePointer?
        private unowned let database: SQLiteDatabase
        private let sql: String

        fileprivate init(database: SQLiteDatabase, sql: String) throws {
            self.database = database
            self.sql = sql
            let code = sqlite3_prepare_v2(database.handle, sql, -1, &pointer, nil)
            guard code == SQLITE_OK else { throw database.fail(code, sql) }
        }

        deinit { sqlite3_finalize(pointer) }

        @discardableResult
        func bind(_ index: Int32, _ value: String) -> Statement {
            // SQLITE_TRANSIENT because Swift may hand us a temporary UTF-8
            // buffer that is gone before the statement runs.
            sqlite3_bind_text(pointer, index, value, -1, SQLITE_TRANSIENT)
            return self
        }

        @discardableResult
        func bind(_ index: Int32, _ value: Int) -> Statement {
            sqlite3_bind_int64(pointer, index, Int64(value))
            return self
        }

        @discardableResult
        func bind(_ index: Int32, _ value: Double) -> Statement {
            sqlite3_bind_double(pointer, index, value)
            return self
        }

        func string(_ column: Int32) -> String {
            sqlite3_column_text(pointer, column).map { String(cString: $0) } ?? ""
        }

        func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(pointer, column)) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(pointer, column) }

        /// Advance one row. `false` means done.
        ///
        /// FTS5 reports a malformed `MATCH` expression *here*, not at prepare
        /// time — a step loop that treats anything other than `SQLITE_ROW` as
        /// "no more rows" silently renders an empty result set for a broken
        /// query.
        func step() throws -> Bool {
            let code = sqlite3_step(pointer)
            switch code {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw database.fail(code, sql)
            }
        }

        func reset() {
            sqlite3_reset(pointer)
            sqlite3_clear_bindings(pointer)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        try Statement(database: self, sql: sql)
    }

    /// Run `body` inside `BEGIN IMMEDIATE` … `COMMIT`, rolling back on any
    /// error thrown.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}
