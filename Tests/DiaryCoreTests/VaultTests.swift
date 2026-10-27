import Foundation
import CryptoKit
import DiaryCore

final class VaultTests {
    var failures = 0
    func check(_ condition: Bool, file: StaticString = #filePath, line: UInt = #line) { if !condition { failures += 1; print("FAIL: \(file):\(line)") } }
    func checkThrows<T>(_ operation: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); failures += 1; print("FAIL: expected error at \(file):\(line)") } catch {}
    }
    let password="a-long-test-passphrase-2026"
    func location() throws -> URL {
        let base=ProcessInfo.processInfo.environment["SHIGUANG_TEST_ROOT"].map {URL(fileURLWithPath:$0)} ?? FileManager.default.temporaryDirectory.appendingPathComponent("ShiguangTests")
        let path=base.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true)
        return path
    }
    func testPasswordRoundtripAndAtRestEncryption() async throws {
        let base=try location(); defer {try? FileManager.default.removeItem(at:base)}
        let store=VaultStore(root:base.appendingPathComponent("Vault"))
        _=try await store.create(password:password)
        var entry=DiaryEntry(); entry.title="秘密标题-水杉"; entry.text="unique-secret-body-73291"; entry.tags=["私密标签"]
        try await store.save(entry)
        check(try await store.list(search:"水杉").count==1)
        check(try await store.list(search:"73291").count==1)
        let disk=try Data(contentsOf:base.appendingPathComponent("Vault/diary.db"))
        check(!disk.starts(with:Data("SQLite format 3".utf8)))
        check(disk.range(of:Data(entry.text.utf8))==nil)
        let wal=try Data(contentsOf:base.appendingPathComponent("Vault/diary.db-wal"))
        check(wal.range(of:Data(entry.text.utf8))==nil)
        await store.lock()
        await checkThrows {try await store.unlock(password:"wrong-password")}
        try await store.unlock(password:password)
        check(try await store.entry(entry.id)?.text==entry.text)
        await store.lock()
    }
    func testRecoveryAndPasswordRotation() async throws {
        let base=try location(); defer {try? FileManager.default.removeItem(at:base)}
        let store=VaultStore(root:base.appendingPathComponent("Vault"))
        let recovery=try await store.create(password:password)
        var entry=DiaryEntry(); entry.text="不能丢失的日记"; try await store.save(entry)
        await store.lock()
        try await store.recover(recovery:recovery,newPassword:"new-strong-passphrase")
        check(try await store.entry(entry.id)?.text==entry.text)
        await store.lock()
        await checkThrows {try await store.unlock(password:password)}
        try await store.unlock(password:"new-strong-passphrase")
        await store.lock()
    }
    func testAttachmentTamperingAndCrossFileSwapsAreRejected() async throws {
        let base=try location(); defer {try? FileManager.default.removeItem(at:base)}
        let store=VaultStore(root:base.appendingPathComponent("Vault")); _=try await store.create(password:password)
        let original=Data("private photo bytes".utf8)
        let a=try await store.addAttachment(original); let b=try await store.addAttachment(Data("other image".utf8))
        check(try await store.attachment(a)==original)
        let path=base.appendingPathComponent("Vault/attachments/\(a.uuidString).bin")
        let other=base.appendingPathComponent("Vault/attachments/\(b.uuidString).bin")
        var ciphertext=try Data(contentsOf:path)
        check(ciphertext.range(of:original)==nil)
        try ciphertext.write(to:other)
        await checkThrows {try await store.attachment(b)}
        ciphertext[5] ^= 1; try ciphertext.write(to:path)
        await checkThrows {try await store.attachment(a)}
        await store.lock()
    }
    func testCompleteBackupRestoresAndRejectsCorruption() async throws {
        let base=try location(); defer {try? FileManager.default.removeItem(at:base)}
        let store=VaultStore(root:base.appendingPathComponent("Vault")); let recovery=try await store.create(password:password)
        var entry=DiaryEntry(); entry.title="备份里的日记"; entry.text="原始版本"; entry.attachmentIDs=[try await store.addAttachment(Data("photo".utf8))]
        try await store.save(entry)
        let backup=try await store.backup(to:base.appendingPathComponent("Backups"))
        entry.text="新的版本"; try await store.save(entry,forceVersion:true)
        let restored=VaultStore(root:base.appendingPathComponent("Restored"))
        _=try await restored.restoreBackup(from:backup,password:recovery,recovery:true)
        check(try await restored.entry(entry.id)?.text=="原始版本")
        check(try await restored.attachment(entry.attachmentIDs[0])==Data("photo".utf8))
        await restored.lock()
        let file=backup.appendingPathComponent("diary.db"); var bytes=try Data(contentsOf:file); bytes[90] ^= 1; try bytes.write(to:file)
        await checkThrows {try await store.verifyBackup(backup,password:password)}
        await store.lock()
    }
    func testTrashVersionAndPendingRecovery() async throws {
        let base=try location(); defer {try? FileManager.default.removeItem(at:base)}
        let store=VaultStore(root:base.appendingPathComponent("Vault")); _=try await store.create(password:password)
        var entry=DiaryEntry(); entry.text="first"; try await store.save(entry)
        entry.text="second"; try await store.save(entry,forceVersion:true)
        check(try await store.versions(entry.id).first?.entry.text=="first")
        let pending=try await store.protectPending(entry)
        await store.lock(); try await store.unlock(password:password)
        check(try await store.restorePending(pending).text=="second")
        try await store.trash(entry.id)
        check(try await store.entry(entry.id)?.deletedAt != nil)
        try await store.trash(entry.id,restore:true)
        check(try await store.entry(entry.id)?.deletedAt == nil)
        await store.lock()
    }
    func testIncompleteOrMalformedVaultNeverOverwritten() async throws {
        let base=try location(); defer {try? FileManager.default.removeItem(at:base)}
        let root=base.appendingPathComponent("Vault"); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let protectedFile=root.appendingPathComponent("diary.db"); let original=Data("existing data".utf8); try original.write(to:protectedFile)
        let store=VaultStore(root:root)
        await checkThrows {try await store.create(password:password)}
        check(try Data(contentsOf:protectedFile)==original)
    }
    func testClearingExistingEntryPersistsAndNewBlankIsSkipped() async throws {
        let base=try location();defer{try? FileManager.default.removeItem(at:base)}
        let store=VaultStore(root:base.appendingPathComponent("Vault"));_=try await store.create(password:password)
        let blank=DiaryEntry();try await store.save(blank)
        check(try await store.list().isEmpty)
        var item=DiaryEntry();item.text="clear this body";try await store.save(item)
        item.text="";try await store.save(item)
        await store.lock();try await store.unlock(password:password)
        check(try await store.entry(item.id)?.text=="")
        check(try await store.versions(item.id).first?.entry.text=="clear this body")
        await store.lock()
    }
    func testSharedImageSurvivesDeletingOneEntry() async throws {
        let base=try location();defer{try? FileManager.default.removeItem(at:base)}
        let store=VaultStore(root:base.appendingPathComponent("Vault"));_=try await store.create(password:password)
        let bytes=Data("shared picture".utf8);let image=try await store.addAttachment(bytes)
        var a=DiaryEntry();a.attachmentIDs=[image];var b=DiaryEntry();b.attachmentIDs=[image]
        try await store.save(a);try await store.save(b);try await store.purge(a.id)
        check(try await store.attachment(image)==bytes)
        await store.lock()
    }
    func testMissingDatabaseIsNeverRecreatedOnUnlock() async throws {
        let base=try location();defer{try? FileManager.default.removeItem(at:base)}
        let root=base.appendingPathComponent("Vault");let store=VaultStore(root:root)
        _=try await store.create(password:password);await store.lock()
        let database=root.appendingPathComponent("diary.db")
        try FileManager.default.moveItem(at:database,to:base.appendingPathComponent("original.db"))
        await checkThrows {try await store.unlock(password:self.password)}
        check(!FileManager.default.fileExists(atPath:database.path))
    }
    func testWeatherCoordinatesAreCoarsened() {
        let point=WeatherClient.coarse(latitude:30.274123,longitude:120.155786)
        check(abs(point.0-30.25)<0.00001)
        check(abs(point.1-120.15)<0.00001)
    }
}

@main
struct VaultChecks {
    static func main() async {
        let suite = VaultTests()
        let checks: [(String, () async throws -> Void)] = [
            ("Password, encrypted database/WAL, search", suite.testPasswordRoundtripAndAtRestEncryption),
            ("Recovery and password rotation", suite.testRecoveryAndPasswordRotation),
            ("Attachment tampering and file swaps", suite.testAttachmentTamperingAndCrossFileSwapsAreRejected),
            ("Backup restore and corruption rejection", suite.testCompleteBackupRestoresAndRejectsCorruption),
            ("Versions, trash and pending recovery", suite.testTrashVersionAndPendingRecovery),
            ("Incomplete vault cannot be overwritten", suite.testIncompleteOrMalformedVaultNeverOverwritten),
            ("Weather coordinate coarsening", { suite.testWeatherCoordinatesAreCoarsened() }),
            ("Cleared entries persist; new blanks are skipped", suite.testClearingExistingEntryPersistsAndNewBlankIsSkipped),
            ("Shared attachment survives another entry deletion", suite.testSharedImageSurvivesDeletingOneEntry),
            ("Missing database cannot silently become empty", suite.testMissingDatabaseIsNeverRecreatedOnUnlock)
        ]
        for (name, run) in checks {
            let before = suite.failures
            do { try await run() } catch { suite.failures += 1; print("ERROR: \(error)") }
            print("\(suite.failures == before ? "PASS" : "FAIL") · \(name)")
        }
        if ProcessInfo.processInfo.environment["SHIGUANG_TEST_WEATHER"]=="1" {
            do {
                let weather=try await WeatherClient.fetch(latitude:30.25,longitude:120.15,city:"公开样例城市")
                suite.check(weather.temperature.isFinite && abs(weather.observedAt.timeIntervalSinceNow)<7200)
                let cities=try await WeatherClient.search("Hangzhou");suite.check(!cities.isEmpty)
                print("PASS · Live weather and city search using public example coordinates")
            } catch {suite.failures += 1;print("FAIL · Live weather: \(error)")}
        }
        print("\(checks.count) checks completed; \(suite.failures) failures")
        exit(suite.failures == 0 ? 0 : 1)
    }
}
