import Foundation
import CryptoKit

public actor VaultStore {
    public let root: URL
    private var database: EncryptedDatabase?
    private var master: SymmetricKey?
    private var header: VaultHeader?
    private let encoder=JSONEncoder()
    private let decoder=JSONDecoder()
    private let fm=FileManager.default
    public init(root: URL) { self.root=root }
    public func exists() -> Bool { fm.fileExists(atPath:root.appendingPathComponent("vault.json").path) }
    public func vaultID() throws -> UUID { try readHeader(at:root).id }
    public func isUnlocked() -> Bool { database != nil }

    public func create(password: String) throws -> String {
        guard password.count>=10 else {throw DiaryError.invalidInput(L10n.t("请设置至少 10 个字符的密码，推荐使用长短语。"))}
        guard !fm.fileExists(atPath:root.path) else {throw DiaryError.storage(L10n.t("此位置已有保险库数据。为保护它们，请恢复备份或选择新的位置。"))}
        try fm.createDirectory(at:root.deletingLastPathComponent(),withIntermediateDirectories:true)
        let staging=root.deletingLastPathComponent().appendingPathComponent(".creating-"+UUID().uuidString)
        try fm.createDirectory(at:staging,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var promoted=false
        defer {if !promoted {try? fm.removeItem(at:staging)}}
        let id=UUID(); let masterData=try VaultEncryption.random(32); let key=SymmetricKey(data:masterData)
        let recoveryData=try VaultEncryption.random(32); let recoveryKey=SymmetricKey(data:recoveryData)
        let salt=try VaultEncryption.random(16); let wrapping=try VaultEncryption.derive(password:password,salt:salt)
        let h=VaultHeader(id:id,salt:salt,passwordWrap:try VaultEncryption.seal(masterData,key:wrapping,context:"password:"+id.uuidString),recoveryWrap:try VaultEncryption.seal(masterData,key:recoveryKey,context:"recovery:"+id.uuidString))
        let db=try EncryptedDatabase(url:staging.appendingPathComponent("diary.db"),key:VaultEncryption.subkey(key,purpose:"database",id:id))
        try db.checkIntegrity(); db.close()
        try fm.createDirectory(at:staging.appendingPathComponent("attachments"),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try VaultEncryption.atomicWrite(try encoder.encode(h),to:staging.appendingPathComponent("vault.json"))
        try fm.moveItem(at:staging,to:root); promoted=true
        try connect(header:h,key:key)
        try savePreferences(DiaryPreferences())
        return VaultEncryption.recoveryString(recoveryData)
    }
    public func unlock(password: String) throws {
        let h=try readHeader(at:root); let key=try VaultEncryption.unlock(h,password:password); try connect(header:h,key:key)
    }
    public func recover(recovery: String, newPassword: String) throws {
        guard newPassword.count>=10 else {throw DiaryError.invalidInput(L10n.t("新密码至少需要 10 个字符。"))}
        var h=try readHeader(at:root); let key=try VaultEncryption.recover(h,recovery:recovery)
        let salt=try VaultEncryption.random(16); let wrapping=try VaultEncryption.derive(password:newPassword,salt:salt)
        h.salt=salt; h.passwordWrap=try VaultEncryption.seal(VaultEncryption.raw(key),key:wrapping,context:"password:"+h.id.uuidString)
        try connect(header:h,key:key)
        do {try VaultEncryption.atomicWrite(try encoder.encode(h),to:root.appendingPathComponent("vault.json"))}
        catch {lock(); throw error}
    }
    public func changePassword(current: String, new: String) throws {
        guard new.count>=10 else {throw DiaryError.invalidInput(L10n.t("新密码至少需要 10 个字符。"))}
        let old=try readHeader(at:root); let verified=try VaultEncryption.unlock(old,password:current)
        guard let key=master, VaultEncryption.raw(verified)==VaultEncryption.raw(key) else {throw DiaryError.locked}
        var h=old; h.salt=try VaultEncryption.random(16)
        h.passwordWrap=try VaultEncryption.seal(VaultEncryption.raw(key),key:VaultEncryption.derive(password:new,salt:h.salt),context:"password:"+h.id.uuidString)
        try VaultEncryption.atomicWrite(try encoder.encode(h),to:root.appendingPathComponent("vault.json")); header=h
    }
    public func regenerateRecovery(password: String) throws -> String {
        var h=try readHeader(at:root); let verified=try VaultEncryption.unlock(h,password:password)
        guard master != nil else {throw DiaryError.locked}
        let recovery=try VaultEncryption.random(32)
        h.recoveryWrap=try VaultEncryption.seal(VaultEncryption.raw(verified),key:SymmetricKey(data:recovery),context:"recovery:"+h.id.uuidString)
        try VaultEncryption.atomicWrite(try encoder.encode(h),to:root.appendingPathComponent("vault.json")); header=h
        return VaultEncryption.recoveryString(recovery)
    }
    public func unlock(deviceKey: Data) throws {
        guard deviceKey.count==32 else {throw DiaryError.invalidPassword}
        let h=try readHeader(at:root); try connect(header:h,key:SymmetricKey(data:deviceKey))
    }
    public func deviceKey() throws -> Data { guard let master else {throw DiaryError.locked}; return VaultEncryption.raw(master) }
    public func lock() { database?.close(); database=nil; master=nil; header=nil }
    private func connect(header h:VaultHeader,key:SymmetricKey) throws {
        try VaultEncryption.validate(h)
        database?.close(); database=nil; master=nil; header=nil
        let databaseURL=root.appendingPathComponent("diary.db")
        guard fm.fileExists(atPath:databaseURL.path),try databaseURL.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey]).isRegularFile==true,try databaseURL.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else {throw DiaryError.damaged(L10n.t("数据库文件缺失或无效，请使用完整备份恢复。"))}
        let db=try EncryptedDatabase(url:databaseURL,key:VaultEncryption.subkey(key,purpose:"database",id:h.id))
        database=db; master=key; header=h
        try prune()
    }
    private func db() throws -> EncryptedDatabase {guard let database else {throw DiaryError.locked}; return database}
    private func readHeader(at location:URL) throws -> VaultHeader {
        let url=location.appendingPathComponent("vault.json")
        guard (try url.resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink != true else {throw DiaryError.damaged(L10n.t("保险库头文件不能是符号链接。"))}
        let data=try Data(contentsOf:url); guard data.count<65536 else {throw DiaryError.damaged(L10n.t("保险库头文件无效。"))}
        let h=try decoder.decode(VaultHeader.self,from:data); try VaultEncryption.validate(h); return h
    }
    public func list(search:String = "") throws -> [EntrySummary] {
        let connection=try db(); var values=[EncryptedDatabase.Value]()
        var sql="SELECT id,date,title,preview,notebook,mood,tags,favorite,deleted_at,has_photos,weather FROM entries"
        if !search.isEmpty {
            sql += " WHERE instr(lower(search_text),lower(?)) > 0"
            values.append(.text(search))
        }
        sql += " ORDER BY date DESC,updated_at DESC"
        return try connection.query(sql,values).compactMap { row in
            guard let id=UUID(uuidString:row["id"]!.string) else {return nil}
            return EntrySummary(id:id,date:Date(timeIntervalSince1970:row["date"]!.double),title:row["title"]!.string,preview:row["preview"]!.string,notebook:row["notebook"]!.string,mood:row["mood"]!.string,tags:(try? decoder.decode([String].self,from:row["tags"]!.data)) ?? [],favorite:row["favorite"]!.double != 0,deletedAt:row["deleted_at"]!.isNull ? nil : Date(timeIntervalSince1970:row["deleted_at"]!.double),hasPhotos:row["has_photos"]!.double != 0,weather:try? decoder.decode(WeatherSnapshot.self,from:row["weather"]!.data))
        }
    }
    public func entry(_ id: UUID) throws -> DiaryEntry? {
        let rows=try db().query("SELECT payload FROM entries WHERE id=?",[.text(id.uuidString)])
        guard let data=rows.first?["payload"]?.data else {return nil}
        return try decoder.decode(DiaryEntry.self,from:data)
    }
    public func save(_ entry: DiaryEntry, forceVersion: Bool = false) throws {
        let connection=try db()
        if entry.isEmpty,try self.entry(entry.id)==nil {return}
        var record=entry; record.updatedAt=Date()
        let payload=try encoder.encode(record)
        let tags=try encoder.encode(record.tags)
        let weather:EncryptedDatabase.Value=try record.weather.map {.blob(try encoder.encode($0))} ?? .null
        try connection.transaction {
            if let previous=try self.entry(record.id), previous != record {
                let latest=try connection.query("SELECT max(saved_at) AS latest FROM versions WHERE entry_id=?",[.text(record.id.uuidString)]).first?["latest"]?.double ?? 0
                if forceVersion || Date().timeIntervalSince1970-latest>300 {
                    try connection.execute("INSERT INTO versions VALUES(?,?,?,?)",[.text(UUID().uuidString),.text(record.id.uuidString),.number(Date().timeIntervalSince1970),.blob(try encoder.encode(previous))])
                }
            }
            try connection.execute("""
            INSERT INTO entries(id,date,title,preview,search_text,notebook,mood,tags,favorite,deleted_at,has_photos,weather,payload,updated_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET date=excluded.date,title=excluded.title,preview=excluded.preview,search_text=excluded.search_text,notebook=excluded.notebook,mood=excluded.mood,tags=excluded.tags,favorite=excluded.favorite,deleted_at=excluded.deleted_at,has_photos=excluded.has_photos,weather=excluded.weather,payload=excluded.payload,updated_at=excluded.updated_at
            """,[.text(record.id.uuidString),.number(record.date.timeIntervalSince1970),.text(record.displayTitle),.text(String(record.text.replacingOccurrences(of:"\u{fffc}",with:"").prefix(150))),.text([record.title,record.text,record.tags.joined(separator:" ")].joined(separator:"\n")),.text(record.notebook),.text(record.mood),.blob(tags),.integer(record.favorite ? 1:0),record.deletedAt.map {.number($0.timeIntervalSince1970)} ?? .null,.integer(record.attachmentIDs.isEmpty ? 0:1),weather,.blob(payload),.number(record.updatedAt.timeIntervalSince1970)])
        }
    }
    public func versions(_ id:UUID) throws -> [EntryVersion] {
        try db().query("SELECT id,saved_at,payload FROM versions WHERE entry_id=? ORDER BY saved_at DESC",[.text(id.uuidString)]).map {row in
            EntryVersion(id:UUID(uuidString:row["id"]!.string)!,savedAt:Date(timeIntervalSince1970:row["saved_at"]!.double),entry:try decoder.decode(DiaryEntry.self,from:row["payload"]!.data))
        }
    }
    public func trash(_ id:UUID, restore:Bool = false) throws {
        guard var item=try entry(id) else {return}; item.deletedAt=restore ? nil:Date(); try save(item,forceVersion:true)
    }
    public func purge(_ id:UUID) throws {
        let connection=try db(); var ids=Set<UUID>()
        if let item=try entry(id) {ids.formUnion(item.attachmentIDs)}
        for v in try versions(id) {ids.formUnion(v.entry.attachmentIDs)}
        try connection.execute("DELETE FROM entries WHERE id=?",[.text(id.uuidString)])
        let referenced=try referencedAttachmentIDs()
        for attachment in ids.subtracting(referenced) {try? fm.removeItem(at:attachmentURL(attachment))}
    }
    private func referencedAttachmentIDs() throws -> Set<UUID> {
        let rows=try db().query("SELECT payload FROM entries UNION ALL SELECT payload FROM versions")
        var ids=Set<UUID>()
        for row in rows {if let data=row["payload"]?.data {ids.formUnion(try decoder.decode(DiaryEntry.self,from:data).attachmentIDs)}}
        return ids
    }
    private func prune() throws {
        let cutoff=Date().addingTimeInterval(-30*86400).timeIntervalSince1970
        let old=try db().query("SELECT id FROM entries WHERE deleted_at IS NOT NULL AND deleted_at<?",[.number(cutoff)])
        for row in old {if let id=UUID(uuidString:row["id"]!.string) {try purge(id)}}
        try db().execute("DELETE FROM versions WHERE saved_at<?",[.number(cutoff)])
        if !fm.fileExists(atPath:root.deletingLastPathComponent().appendingPathComponent("pending.enc").path) {
            let referenced=try referencedAttachmentIDs()
            for url in try fm.contentsOfDirectory(at:root.appendingPathComponent("attachments"),includingPropertiesForKeys:[.contentModificationDateKey]) {
                if let id=UUID(uuidString:url.deletingPathExtension().lastPathComponent),url.pathExtension=="bin",!referenced.contains(id),let modified=try url.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate,Date().timeIntervalSince(modified)>86400 {try? fm.removeItem(at:url)}
            }
        }
    }
    public func savePreferences(_ value:DiaryPreferences) throws {try saveSetting(encoder.encode(value),key:"preferences")}
    public func preferences() throws -> DiaryPreferences {guard let data=try setting("preferences") else {return DiaryPreferences()}; return try decoder.decode(DiaryPreferences.self,from:data)}
    public func saveSetting(_ value:Data,key:String) throws {try db().execute("INSERT INTO preferences VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",[.text(key),.blob(value)])}
    public func setting(_ key:String) throws -> Data? {try db().query("SELECT value FROM preferences WHERE key=?",[.text(key)]).first?["value"]?.data}
    private func attachmentURL(_ id:UUID) -> URL {root.appendingPathComponent("attachments").appendingPathComponent(id.uuidString+".bin")}
    public func addAttachment(_ data:Data,id:UUID = UUID()) throws -> UUID {
        guard let master,let header else {throw DiaryError.locked}
        guard data.count<=50*1024*1024 else {throw DiaryError.invalidInput(L10n.t("单张图片不能超过 50 MB。"))}
        let key=VaultEncryption.subkey(master,purpose:"attachments",id:header.id)
        let sealed=try VaultEncryption.seal(data,key:key,context:"attachment:"+header.id.uuidString+":"+id.uuidString)
        try VaultEncryption.atomicWrite(sealed,to:attachmentURL(id)); return id
    }
    public func attachment(_ id:UUID) throws -> Data {
        guard let master,let header else {throw DiaryError.locked}
        do {return try VaultEncryption.open(Data(contentsOf:attachmentURL(id)),key:VaultEncryption.subkey(master,purpose:"attachments",id:header.id),context:"attachment:"+header.id.uuidString+":"+id.uuidString)}
        catch {throw DiaryError.damaged(L10n.t("图片无法读取或未通过完整性校验。"))}
    }
    public func protectPending(_ entry:DiaryEntry) throws -> Data {
        guard let master,let header else {throw DiaryError.locked}
        return try VaultEncryption.seal(encoder.encode(entry),key:VaultEncryption.subkey(master,purpose:"pending",id:header.id),context:"pending:"+header.id.uuidString)
    }
    public func restorePending(_ data:Data) throws -> DiaryEntry {
        guard let master,let header else {throw DiaryError.locked}
        return try decoder.decode(DiaryEntry.self,from:VaultEncryption.open(data,key:VaultEncryption.subkey(master,purpose:"pending",id:header.id),context:"pending:"+header.id.uuidString))
    }

    public func backup(to directory:URL) throws -> URL {
        let connection=try db(); guard let master,let header else {throw DiaryError.locked}
        try fm.createDirectory(at:directory,withIntermediateDirectories:true)
        let staging=directory.appendingPathComponent(".partial-"+UUID().uuidString,isDirectory:true)
        try fm.createDirectory(at:staging,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer {try? fm.removeItem(at:staging)}
        try VaultEncryption.atomicWrite(encoder.encode(header),to:staging.appendingPathComponent("vault.json"))
        try connection.snapshot(to:staging.appendingPathComponent("diary.db"),key:VaultEncryption.subkey(master,purpose:"database",id:header.id))
        try fm.copyItem(at:root.appendingPathComponent("attachments"),to:staging.appendingPathComponent("attachments"))
        let files=try manifestFiles(in:staging)
        let manifest=BackupManifest(vaultID:header.id,createdAt:Date(),files:files)
        let data=try VaultEncryption.seal(encoder.encode(manifest),key:VaultEncryption.subkey(master,purpose:"backup",id:header.id),context:"manifest:"+header.id.uuidString)
        try VaultEncryption.atomicWrite(data,to:staging.appendingPathComponent("manifest.enc"))
        _=try verifyBackup(staging,key:master,header:header)
        let formatter=DateFormatter(); formatter.dateFormat="yyyyMMdd-HHmmss"
        let target=directory.appendingPathComponent("拾光-"+formatter.string(from:Date())+"-"+UUID().uuidString.prefix(6)+".shiguangbackup",isDirectory:true)
        try fm.moveItem(at:staging,to:target)
        return target
    }
    public func verifyBackup(_ directory:URL,password:String,recovery:Bool = false) throws -> BackupManifest {
        let h=try readHeader(at:directory)
        let key=try recovery ? VaultEncryption.recover(h,recovery:password):VaultEncryption.unlock(h,password:password)
        return try verifyBackup(directory,key:key,header:h)
    }
    private func verifyBackup(_ directory:URL,key:SymmetricKey,header h:VaultHeader) throws -> BackupManifest {
        let data=try Data(contentsOf:directory.appendingPathComponent("manifest.enc"))
        guard data.count<20*1024*1024 else {throw DiaryError.damaged(L10n.t("备份清单过大。"))}
        let manifest:BackupManifest
        do {manifest=try decoder.decode(BackupManifest.self,from:VaultEncryption.open(data,key:VaultEncryption.subkey(key,purpose:"backup",id:h.id),context:"manifest:"+h.id.uuidString))}
        catch {throw DiaryError.damaged(L10n.t("备份清单未通过认证。"))}
        guard manifest.version==1, manifest.vaultID==h.id else {throw DiaryError.damaged(L10n.t("备份格式或保险库标识不符。"))}
        let actual=try manifestFiles(in:directory)
        guard actual==manifest.files, actual["vault.json"] != nil, actual["diary.db"] != nil else {throw DiaryError.damaged(L10n.t("备份文件缺失或发生改动，请选择完整的备份。"))}
        return manifest
    }
    private func manifestFiles(in directory:URL) throws -> [String:String] {
        guard (try directory.resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink != true else {throw DiaryError.damaged(L10n.t("备份位置不能是符号链接。"))}
        guard let enumerator=fm.enumerator(at:directory,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey],options:[]) else {throw DiaryError.storage(L10n.t("无法读取备份。"))}
        var files=[String:String]()
        for case let url as URL in enumerator {
            let values=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
            guard values.isSymbolicLink != true else {throw DiaryError.damaged(L10n.t("备份中含有符号链接，无法恢复。"))}
            guard values.isRegularFile==true else {continue}
            let relative=String(url.path.dropFirst(directory.path.count+1))
            if relative=="manifest.enc" {continue}
            guard relative=="vault.json" || relative=="diary.db" || (relative.hasPrefix("attachments/") && UUID(uuidString:url.deletingPathExtension().lastPathComponent) != nil && url.pathExtension=="bin") else {throw DiaryError.damaged(L10n.t("备份中有不支持的文件。"))}
            guard (values.fileSize ?? 0)<=2_000_000_000, files.count<100000 else {throw DiaryError.damaged(L10n.t("备份超过支持的大小。"))}
            files[relative]=VaultEncryption.digest(try Data(contentsOf:url,options:.mappedIfSafe))
        }; return files
    }
    public func restoreBackup(from directory:URL,password:String,recovery:Bool = false) throws -> URL? {
        let h=try readHeader(at:directory)
        let key=try recovery ? VaultEncryption.recover(h,recovery:password):VaultEncryption.unlock(h,password:password)
        _=try verifyBackup(directory,key:key,header:h)
        let staging=root.deletingLastPathComponent().appendingPathComponent(".restoring-"+UUID().uuidString)
        try fm.createDirectory(at:root.deletingLastPathComponent(),withIntermediateDirectories:true)
        try fm.copyItem(at:directory,to:staging)
        defer {try? fm.removeItem(at:staging)}
        let check=try EncryptedDatabase(url:staging.appendingPathComponent("diary.db"),key:VaultEncryption.subkey(key,purpose:"database",id:h.id))
        try check.checkIntegrity(); check.close()
        try fm.removeItem(at:staging.appendingPathComponent("manifest.enc"))
        lock()
        var previous:URL?
        if fm.fileExists(atPath:root.path) {
            let old=root.deletingLastPathComponent().appendingPathComponent("Vault-before-restore-"+UUID().uuidString)
            try fm.moveItem(at:root,to:old); previous=old
        }
        do {try fm.moveItem(at:staging,to:root); try connect(header:h,key:key)}
        catch {
            if let previous, !fm.fileExists(atPath:root.path) {try? fm.moveItem(at:previous,to:root)}
            throw error
        }
        return previous
    }
    public func trimBackups(in directory:URL,keeping count:Int) throws {
        guard let header else {throw DiaryError.locked}
        let backups=try fm.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.creationDateKey]).filter {$0.pathExtension=="shiguangbackup" && $0.lastPathComponent.hasPrefix("拾光-")}.sorted {$0.lastPathComponent>$1.lastPathComponent}
        var own=[URL]()
        for url in backups {if let candidate=try? readHeader(at:url),candidate.id==header.id {own.append(url)}}
        for url in own.dropFirst(max(1,count)) {try fm.removeItem(at:url)}
    }
}
