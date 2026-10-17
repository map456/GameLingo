import Foundation
import SQLite3

/// 很薄的一層 SQLite 包裝（用 macOS 內建的 libsqlite3，不需要另外裝套件）。
final class SQLiteDB {
    enum Value {
        case int(Int64)
        case double(Double)
        case text(String)
        case null
    }

    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        if sqlite3_open(path, &db) != SQLITE_OK {
            throw NSError(domain: "SQLite", code: 1, userInfo: [NSLocalizedDescriptionKey: "無法開啟資料庫 \(path)"])
        }
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA foreign_keys = ON")
    }

    deinit { sqlite3_close(db) }

    var lastInsertID: Int64 { sqlite3_last_insert_rowid(db) }

    func execute(_ sql: String, _ args: [Value] = []) throws {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw error() }
    }

    /// 查詢，每列回傳欄位名 → 值
    func query(_ sql: String, _ args: [Value] = []) throws -> [[String: Value]] {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        var rows: [[String: Value]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Value] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: row[name] = .double(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(stmt, i)))
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    private func prepare(_ sql: String, _ args: [Value]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw error() }
        for (i, v) in args.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case .int(let x): sqlite3_bind_int64(stmt, idx, x)
            case .double(let x): sqlite3_bind_double(stmt, idx, x)
            case .text(let x): sqlite3_bind_text(stmt, idx, x, -1, Self.transient)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    private func error() -> NSError {
        NSError(domain: "SQLite", code: Int(sqlite3_errcode(db)),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
    }
}

extension Dictionary where Key == String, Value == SQLiteDB.Value {
    func int(_ k: String) -> Int64 { if case .int(let x)? = self[k] { return x }; return 0 }
    func double(_ k: String) -> Double {
        switch self[k] {
        case .double(let x)?: return x
        case .int(let x)?: return Double(x)
        default: return 0
        }
    }
    func text(_ k: String) -> String { if case .text(let x)? = self[k] { return x }; return "" }
}
