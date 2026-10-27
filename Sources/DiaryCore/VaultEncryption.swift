import Foundation
import CryptoKit
import Security
import CVaultCrypto

public enum VaultEncryption {
    public static func random(_ count: Int) throws -> Data {
        var data=Data(count:count)
        let result=data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault,count,$0.baseAddress!) }
        guard result == errSecSuccess else { throw DiaryError.storage(L10n.t("无法获取系统安全随机数。")) }
        return data
    }
    public static func derive(password: String, salt: Data) throws -> SymmetricKey {
        guard salt.count == 16 else { throw DiaryError.damaged(L10n.t("保险库的密码参数无效。")) }
        var bytes=Data(password.utf8); var output=Data(count:32)
        defer { bytes.withUnsafeMutableBytes { sg_zero($0.baseAddress,$0.count) }; output.withUnsafeMutableBytes { sg_zero($0.baseAddress,$0.count) } }
        let result=output.withUnsafeMutableBytes { out in salt.withUnsafeBytes { saltBytes in bytes.withUnsafeBytes { pass in
            sg_argon2id(pass.bindMemory(to:UInt8.self).baseAddress,pass.count,saltBytes.bindMemory(to:UInt8.self).baseAddress,out.bindMemory(to:UInt8.self).baseAddress)
        } } }
        guard result == 0 else { throw DiaryError.storage(L10n.t("无法完成密码派生，请释放内存后再试。")) }
        return SymmetricKey(data:output)
    }
    public static func seal(_ data: Data, key: SymmetricKey, context: String) throws -> Data {
        try AES.GCM.seal(data,using:key,authenticating:Data(context.utf8)).combined!
    }
    public static func open(_ data: Data, key: SymmetricKey, context: String) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined:data),using:key,authenticating:Data(context.utf8))
    }
    public static func subkey(_ master: SymmetricKey, purpose: String, id: UUID) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial:master,salt:Data(id.uuidString.utf8),info:Data(purpose.utf8),outputByteCount:32)
    }
    public static func raw(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }
    public static func recoveryString(_ data: Data) -> String {
        let hex=data.map { String(format:"%02X",$0) }.joined()
        return stride(from:0,to:hex.count,by:8).map { offset in
            let start=hex.index(hex.startIndex,offsetBy:offset)
            return String(hex[start..<hex.index(start,offsetBy:8)])
        }.joined(separator:"-")
    }
    public static func parseRecovery(_ string: String) throws -> Data {
        let hex=string.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard hex.count == 64, hex.allSatisfy({$0.isHexDigit}) else { throw DiaryError.invalidRecovery }
        var bytes=Data(); var index=hex.startIndex
        while index < hex.endIndex { let end=hex.index(index,offsetBy:2); guard let byte=UInt8(hex[index..<end],radix:16) else {throw DiaryError.invalidRecovery}; bytes.append(byte); index=end }
        return bytes
    }
    public static func validate(_ header: VaultHeader) throws {
        guard header.version==1, header.kdf=="argon2id13-64MiB-3", header.salt.count==16, header.passwordWrap.count==60, header.recoveryWrap.count==60 else { throw DiaryError.damaged(L10n.t("保险库格式不受支持或已损坏。")) }
    }
    public static func unlock(_ header: VaultHeader, password: String) throws -> SymmetricKey {
        try validate(header)
        do {
            let key=try derive(password:password,salt:header.salt)
            let data=try open(header.passwordWrap,key:key,context:"password:"+header.id.uuidString)
            guard data.count==32 else { throw DiaryError.invalidPassword }
            return SymmetricKey(data:data)
        } catch let error as DiaryError { throw error } catch { throw DiaryError.invalidPassword }
    }
    public static func recover(_ header: VaultHeader, recovery: String) throws -> SymmetricKey {
        try validate(header)
        do { let key=SymmetricKey(data:try parseRecovery(recovery)); let data=try open(header.recoveryWrap,key:key,context:"recovery:"+header.id.uuidString); guard data.count==32 else {throw DiaryError.invalidRecovery}; return SymmetricKey(data:data) }
        catch { throw DiaryError.invalidRecovery }
    }
    public static func digest(_ data: Data) -> String { SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined() }
    public static func atomicWrite(_ data: Data, to url: URL) throws {
        try data.write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
}
