import Foundation
import CryptoKit
import CSQLCipher

final class EncryptedDatabase {
    private var db: OpaquePointer?
    private let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
    init(url: URL, key: SymmetricKey) throws {
        guard sqlite3_open_v2(url.path,&db,SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,nil)==SQLITE_OK else {throw DiaryError.storage(L10n.t("无法打开日记数据库。"))}
        do {
            let bytes=VaultEncryption.raw(key)
            let result=bytes.withUnsafeBytes { sqlite3_key(db,$0.baseAddress,Int32($0.count)) }
            guard result==SQLITE_OK else {throw DiaryError.storage(L10n.t("无法设置数据库密钥。"))}
            try execute("PRAGMA cipher_memory_security = ON")
            try execute("PRAGMA temp_store = MEMORY")
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA secure_delete = ON")
            _ = try query("SELECT count(*) FROM sqlite_master")
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = FULL")
            sqlite3_busy_timeout(db,5000)
            try execute("""
            CREATE TABLE IF NOT EXISTS entries (
              id TEXT PRIMARY KEY, date REAL NOT NULL, title TEXT NOT NULL, preview TEXT NOT NULL,
              search_text TEXT NOT NULL, notebook TEXT NOT NULL, mood TEXT NOT NULL, tags BLOB NOT NULL,
              favorite INTEGER NOT NULL, deleted_at REAL, has_photos INTEGER NOT NULL, weather BLOB,
              payload BLOB NOT NULL, updated_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS entry_date ON entries(date DESC);
            CREATE TABLE IF NOT EXISTS versions(id TEXT PRIMARY KEY, entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE, saved_at REAL NOT NULL, payload BLOB NOT NULL);
            CREATE INDEX IF NOT EXISTS version_entry ON versions(entry_id,saved_at DESC);
            CREATE TABLE IF NOT EXISTS preferences(key TEXT PRIMARY KEY, value BLOB NOT NULL);
            """)
        } catch { close(); throw error }
    }
    deinit { close() }
    func close() { if let db { sqlite3_wal_checkpoint_v2(db,nil,SQLITE_CHECKPOINT_TRUNCATE,nil,nil); sqlite3_close_v2(db); self.db=nil } }
    enum Value { case text(String), blob(Data), number(Double), integer(Int), null }
    func execute(_ sql: String, _ values: [Value] = []) throws {
        guard db != nil else {throw DiaryError.locked}
        if values.isEmpty {
            guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else {throw failure()}
            return
        }
        let stmt=try prepare(sql,values); defer {sqlite3_finalize(stmt)}
        let result=sqlite3_step(stmt)
        guard result==SQLITE_DONE || result==SQLITE_ROW else {throw failure()}
    }
    func query(_ sql: String, _ values: [Value] = []) throws -> [[String:Value]] {
        let stmt=try prepare(sql,values); defer {sqlite3_finalize(stmt)}
        var rows=[[String:Value]]()
        while true {
            let code=sqlite3_step(stmt)
            if code==SQLITE_DONE {break}; guard code==SQLITE_ROW else {throw failure()}
            var row=[String:Value]()
            for col in 0..<sqlite3_column_count(stmt) {
                let name=String(cString:sqlite3_column_name(stmt,col))
                switch sqlite3_column_type(stmt,col) {
                case SQLITE_TEXT: row[name] = .text(String(cString:sqlite3_column_text(stmt,col)))
                case SQLITE_BLOB:
                    let count=Int(sqlite3_column_bytes(stmt,col))
                    row[name] = .blob(count>0 ? Data(bytes:sqlite3_column_blob(stmt,col)!,count:count) : Data())
                case SQLITE_INTEGER: row[name] = .integer(Int(sqlite3_column_int64(stmt,col)))
                case SQLITE_FLOAT: row[name] = .number(sqlite3_column_double(stmt,col))
                default: row[name] = .null
                }
            }; rows.append(row)
        }; return rows
    }
    func transaction(_ work: () throws -> Void) throws { try execute("BEGIN IMMEDIATE"); do {try work(); try execute("COMMIT")} catch {try? execute("ROLLBACK"); throw error} }
    func snapshot(to url: URL, key: SymmetricKey) throws {
        let destination=try EncryptedDatabase(url:url,key:key)
        defer {destination.close()}
        guard let backup=sqlite3_backup_init(destination.db,"main",db,"main") else {throw failure()}
        var code=sqlite3_backup_step(backup,-1)
        let finished=sqlite3_backup_finish(backup)
        if code==SQLITE_DONE {code=finished}
        guard code==SQLITE_OK else {throw DiaryError.storage(L10n.t("无法生成一致的备份快照。"))}
        try destination.checkIntegrity()
    }
    func checkIntegrity() throws {
        let rows=try query("PRAGMA integrity_check")
        guard rows.count==1, rows.first?.values.first?.string=="ok" else {throw DiaryError.damaged(L10n.t("数据库完整性检查失败。"))}
        let cipher=try query("PRAGMA cipher_integrity_check")
        guard cipher.isEmpty else {throw DiaryError.damaged(L10n.t("数据库加密完整性检查失败。"))}
    }
    private func prepare(_ sql: String, _ values:[Value]) throws -> OpaquePointer {
        guard db != nil else {throw DiaryError.locked}
        var stmt:OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&stmt,nil)==SQLITE_OK, let stmt else {throw failure()}
        do {
            for (offset,value) in values.enumerated() {
                let i=Int32(offset+1); let result:Int32
                switch value {
                case .text(let text): result=sqlite3_bind_text(stmt,i,text,-1,transient)
                case .blob(let data): result=data.withUnsafeBytes {sqlite3_bind_blob(stmt,i,$0.baseAddress,Int32($0.count),transient)}
                case .number(let number): result=sqlite3_bind_double(stmt,i,number)
                case .integer(let number): result=sqlite3_bind_int64(stmt,i,Int64(number))
                case .null: result=sqlite3_bind_null(stmt,i)
                }
                guard result==SQLITE_OK else {throw failure()}
            }; return stmt
        } catch {sqlite3_finalize(stmt); throw error}
    }
    private func failure() -> DiaryError {
        let code=sqlite3_extended_errcode(db)
        if code==SQLITE_FULL {return .storage(L10n.t("磁盘空间不足，日记尚未保存。请释放空间后重试。"))}
        if code==SQLITE_NOTADB || code==SQLITE_CORRUPT {return .damaged(L10n.t("无法验证数据库，请检查密码或使用完整备份恢复。"))}
        return .storage(L10n.t("日记存储失败（错误码 \(code)）。请重试或检查文件权限。"))
    }
}

extension EncryptedDatabase.Value {
    var string:String { if case .text(let value)=self{return value}; return "" }
    var data:Data { if case .blob(let value)=self{return value}; return Data() }
    var double:Double { switch self {case .number(let value):return value;case .integer(let value):return Double(value);default:return 0} }
    var isNull:Bool { if case .null=self{return true}; return false }
}
