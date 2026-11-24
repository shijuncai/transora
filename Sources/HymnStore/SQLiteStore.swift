import Foundation
import SQLite3
import HymnCore

public struct HistoryRecord: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let requestID: String
    public let sourceLang: String
    public let targetLang: String
    public let sourceText: String
    public let targetText: String
    public let createdAt: Int64
    public let durationMs: Int64
    public let tokenCount: Int
    public let cancelled: Bool
    public let modelTag: String

    public init(
        id: Int64 = 0,
        requestID: String = UUID().uuidString,
        sourceLang: String,
        targetLang: String,
        sourceText: String,
        targetText: String,
        createdAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        durationMs: Int64 = 0,
        tokenCount: Int = 0,
        cancelled: Bool = false,
        modelTag: String = "unspecified"
    ) {
        self.id = id
        self.requestID = requestID
        self.sourceLang = sourceLang
        self.targetLang = targetLang
        self.sourceText = sourceText
        self.targetText = targetText
        self.createdAt = createdAt
        self.durationMs = durationMs
        self.tokenCount = tokenCount
        self.cancelled = cancelled
        self.modelTag = modelTag
    }
}

public struct StoreStats: Sendable, Equatable {
    public let historyCount: Int
    public let termCount: Int
    public let schemaVersion: Int
}

public struct SQLiteFailure: Error, Sendable, CustomStringConvertible, Equatable {
    public let code: String
    public let message: String
    public var description: String { "SQLite[\(code)] \(message)" }
    init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
}

/// 历史记录 + 术语库存储。
///
/// 使用系统 libsqlite3（无第三方依赖），全程离线。
/// `@unchecked Sendable` 的依据：所有对 `db` 句柄的访问都在 `lock` 临界区内，
/// 连接以 FULLMUTEX 打开，跨 actor 传递的是本类的不可变引用。
public final class SQLiteStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    private let path: String

    public init(path: String = ":memory:") throws {
        self.path = path
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(
            path, &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard rc == SQLITE_OK, let handle else {
            throw SQLiteFailure("OPEN_\(rc)", String(cString: sqlite3_errstr(rc)))
        }
        db = handle
        try exec("PRAGMA busy_timeout = 5000")
        try exec("PRAGMA foreign_keys = ON")
        if path != ":memory:" { try exec("PRAGMA journal_mode = WAL") }
        try exec("PRAGMA synchronous = NORMAL")
        try migrate()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        if let db { sqlite3_close(db) }
        self.db = nil
    }

    public var databasePath: String { path }

    // MARK: - Schema

    private func migrate() throws {
        let version = try scalarInt("PRAGMA user_version") ?? 0
        if version < 1 {
            try exec("""
                CREATE TABLE IF NOT EXISTS history (
                    id           INTEGER PRIMARY KEY AUTOINCREMENT,
                    request_id   TEXT NOT NULL,
                    source_lang  TEXT NOT NULL,
                    target_lang  TEXT NOT NULL,
                    source_text  TEXT NOT NULL,
                    target_text  TEXT NOT NULL,
                    created_at   INTEGER NOT NULL,
                    duration_ms  INTEGER NOT NULL,
                    token_count  INTEGER NOT NULL,
                    cancelled    INTEGER NOT NULL DEFAULT 0,
                    model_tag    TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_history_created ON history(created_at DESC);
                CREATE INDEX IF NOT EXISTS idx_history_langs   ON history(source_lang, target_lang);
                CREATE TABLE IF NOT EXISTS terms (
                    id           INTEGER PRIMARY KEY AUTOINCREMENT,
                    source       TEXT NOT NULL,
                    target       TEXT NOT NULL,
                    source_lang  TEXT NOT NULL,
                    target_lang  TEXT NOT NULL,
                    note         TEXT NOT NULL DEFAULT '',
                    created_at   INTEGER NOT NULL,
                    UNIQUE(source, source_lang, target_lang)
                );
                CREATE INDEX IF NOT EXISTS idx_terms_langs ON terms(source_lang, target_lang);
                PRAGMA user_version = 1;
                """)
        }
    }

    // MARK: - History

    public func insertHistory(_ r: HistoryRecord) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return try insertHistoryLocked(r)
    }

    private func insertHistoryLocked(_ r: HistoryRecord) throws -> Int64 {
        let stmt = try prepare("""
            INSERT INTO history
              (request_id, source_lang, target_lang, source_text, target_text,
               created_at, duration_ms, token_count, cancelled, model_tag)
            VALUES (?,?,?,?,?,?,?,?,?,?)
            """)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, r.requestID)
        bind(stmt, 2, r.sourceLang)
        bind(stmt, 3, r.targetLang)
        bind(stmt, 4, r.sourceText)
        bind(stmt, 5, r.targetText)
        sqlite3_bind_int64(stmt, 6, r.createdAt)
        sqlite3_bind_int64(stmt, 7, r.durationMs)
        sqlite3_bind_int(stmt, 8, Int32(r.tokenCount))
        sqlite3_bind_int(stmt, 9, r.cancelled ? 1 : 0)
        bind(stmt, 10, r.modelTag)
        try stepDone(stmt)
        return sqlite3_last_insert_rowid(db)
    }

    /// 事务批量写入，返回耗时（纳秒）用于性能报告。
    public func insertHistoryBatch(_ records: [HistoryRecord]) throws -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        let start = DispatchTime.now().uptimeNanoseconds
        try exec("BEGIN IMMEDIATE")
        do {
            for r in records { _ = try insertHistoryLocked(r) }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return DispatchTime.now().uptimeNanoseconds - start
    }

    public func fetchHistory(limit: Int = 20, offset: Int = 0, search: String? = nil) throws -> [HistoryRecord] {
        lock.lock(); defer { lock.unlock() }
        let sql: String
        if let search, !search.isEmpty {
            sql = """
                SELECT id, request_id, source_lang, target_lang, source_text, target_text,
                       created_at, duration_ms, token_count, cancelled, model_tag
                FROM history
                WHERE source_text LIKE ? ESCAPE '\\' OR target_text LIKE ? ESCAPE '\\'
                ORDER BY created_at DESC, id DESC LIMIT ? OFFSET ?
                """
        } else {
            sql = """
                SELECT id, request_id, source_lang, target_lang, source_text, target_text,
                       created_at, duration_ms, token_count, cancelled, model_tag
                FROM history ORDER BY created_at DESC, id DESC LIMIT ? OFFSET ?
                """
        }
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var bindIndex: Int32 = 1
        if let search, !search.isEmpty {
            let pattern = "%" + escapeLike(search) + "%"
            bind(stmt, bindIndex, pattern); bindIndex += 1
            bind(stmt, bindIndex, pattern); bindIndex += 1
        }
        sqlite3_bind_int64(stmt, bindIndex, Int64(limit)); bindIndex += 1
        sqlite3_bind_int64(stmt, bindIndex, Int64(offset))
        return try collectHistory(stmt)
    }

    public func countHistory() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        return try scalarInt("SELECT COUNT(*) FROM history") ?? 0
    }

    public func deleteHistory(id: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare("DELETE FROM history WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        try stepDone(stmt)
    }

    // MARK: - Terms

    @discardableResult
    public func upsertTerm(
        source: String, target: String,
        languages: LanguagePair, note: String = ""
    ) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare("""
            INSERT INTO terms (source, target, source_lang, target_lang, note, created_at)
            VALUES (?,?,?,?,?,?)
            ON CONFLICT(source, source_lang, target_lang)
            DO UPDATE SET target = excluded.target, note = excluded.note
            """)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, source)
        bind(stmt, 2, target)
        bind(stmt, 3, languages.source)
        bind(stmt, 4, languages.target)
        bind(stmt, 5, note)
        sqlite3_bind_int64(stmt, 6, Int64(Date().timeIntervalSince1970 * 1000))
        try stepDone(stmt)
        return sqlite3_last_insert_rowid(db)
    }

    public func fetchTerms(languages: LanguagePair) throws -> [GlossaryEntry] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare("""
            SELECT id, source, target, note FROM terms
            WHERE source_lang = ? AND target_lang = ?
            ORDER BY LENGTH(source) DESC, id ASC
            """)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, languages.source)
        bind(stmt, 2, languages.target)
        var result: [GlossaryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(GlossaryEntry(
                id: sqlite3_column_int64(stmt, 0),
                source: columnString(stmt, 1),
                target: columnString(stmt, 2),
                languages: languages,
                note: columnString(stmt, 3)
            ))
        }
        return result
    }

    public func countTerms() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        return try scalarInt("SELECT COUNT(*) FROM terms") ?? 0
    }

    public func deleteTerm(id: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare("DELETE FROM terms WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        try stepDone(stmt)
    }

    public func stats() throws -> StoreStats {
        lock.lock(); defer { lock.unlock() }
        return StoreStats(
            historyCount: try scalarInt("SELECT COUNT(*) FROM history") ?? 0,
            termCount: try scalarInt("SELECT COUNT(*) FROM terms") ?? 0,
            schemaVersion: try scalarInt("PRAGMA user_version") ?? 0
        )
    }

    public func clearAll() throws {
        lock.lock(); defer { lock.unlock() }
        try exec("DELETE FROM history; DELETE FROM terms;")
    }

    // MARK: - C API helpers

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? errorMessage()
            sqlite3_free(err)
            throw SQLiteFailure("EXEC_\(rc)", msg)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw SQLiteFailure("PREPARE_\(rc)", errorMessage())
        }
        return stmt
    }

    private func stepDone(_ stmt: OpaquePointer) throws {
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw SQLiteFailure("STEP_\(rc)", errorMessage())
        }
    }

    private func scalarInt(_ sql: String) throws -> Int? {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func bind(_ stmt: OpaquePointer, _ idx: Int32, _ value: String) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, idx, value, -1, transient)
    }

    private func columnString(_ stmt: OpaquePointer, _ idx: Int32) -> String {
        guard let p = sqlite3_column_text(stmt, idx) else { return "" }
        return String(cString: p)
    }

    private func errorMessage() -> String {
        guard let db else { return "database closed" }
        return String(cString: sqlite3_errmsg(db))
    }

    private func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "%", with: "\\%")
         .replacingOccurrences(of: "_", with: "\\_")
    }

    private func collectHistory(_ stmt: OpaquePointer) throws -> [HistoryRecord] {
        var result: [HistoryRecord] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw SQLiteFailure("STEP_\(rc)", errorMessage())
            }
            result.append(HistoryRecord(
                id: sqlite3_column_int64(stmt, 0),
                requestID: columnString(stmt, 1),
                sourceLang: columnString(stmt, 2),
                targetLang: columnString(stmt, 3),
                sourceText: columnString(stmt, 4),
                targetText: columnString(stmt, 5),
                createdAt: sqlite3_column_int64(stmt, 6),
                durationMs: sqlite3_column_int64(stmt, 7),
                tokenCount: Int(sqlite3_column_int(stmt, 8)),
                cancelled: sqlite3_column_int(stmt, 9) != 0,
                modelTag: columnString(stmt, 10)
            ))
        }
        return result
    }
}
