import Foundation

public enum DiaryError: LocalizedError {
    case invalidPassword, invalidRecovery, locked, damaged(String), storage(String), invalidInput(String)
    public var errorDescription: String? {
        switch self {
        case .invalidPassword: return L10n.t("密码不正确，或保险库无法验证。")
        case .invalidRecovery: return L10n.t("恢复密钥不正确，请检查完整的密钥。")
        case .locked: return L10n.t("请先解锁日记。")
        case .damaged(let message), .storage(let message), .invalidInput(let message): return message
        }
    }
}

public struct WeatherSnapshot: Codable, Equatable, Sendable {
    public var city: String
    public var temperature: Double
    public var code: Int
    public var observedAt: Date
    public var fetchedAt: Date
    public var timeZone: String
    public var source: String
    public var manual: Bool
    public init(city: String, temperature: Double, code: Int, observedAt: Date = Date(), fetchedAt: Date = Date(), timeZone: String = TimeZone.current.identifier, source: String = "Open-Meteo", manual: Bool = false) {
        self.city=city; self.temperature=temperature; self.code=code; self.observedAt=observedAt; self.fetchedAt=fetchedAt; self.timeZone=timeZone; self.source=source; self.manual=manual
    }
    public var condition: String {
        switch code {
        case 0: return L10n.t("晴"); case 1,2: return L10n.t("少云"); case 3: return L10n.t("多云")
        case 45,48: return L10n.t("雾"); case 51...57: return L10n.t("毛毛雨"); case 61: return L10n.t("小雨")
        case 63,65,66,67: return L10n.t("雨"); case 71...77: return L10n.t("雪")
        case 80...82: return L10n.t("阵雨"); case 85,86: return L10n.t("阵雪"); case 95...99: return L10n.t("雷雨")
        default: return L10n.t("天气")
        }
    }
    public var symbol: String {
        switch code { case 0: return "sun.max"; case 1,2: return "cloud.sun"; case 3: return "cloud"; case 45,48: return "cloud.fog"; case 71...77,85,86: return "cloud.snow"; case 95...99: return "cloud.bolt.rain"; default: return "cloud.rain" }
    }
}

public struct DiaryEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var createdAt: Date
    public var updatedAt: Date
    public var title: String
    public var text: String
    public var richText: Data
    public var notebook: String
    public var mood: String
    public var tags: [String]
    public var favorite: Bool
    public var deletedAt: Date?
    public var weather: WeatherSnapshot?
    public var attachmentIDs: [UUID]
    public var weatherDismissed: Bool
    public init(id: UUID = UUID(), date: Date = Date(), notebook: String = L10n.t("生活碎片")) {
        self.id=id; self.date=date; createdAt=Date(); updatedAt=Date(); title=""; text=""; richText=Data(); self.notebook=notebook; mood=""; tags=[]; favorite=false; deletedAt=nil; weather=nil; attachmentIDs=[]; weatherDismissed=false
    }
    public var isEmpty: Bool { title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && attachmentIDs.isEmpty }
    public var displayTitle: String { title.isEmpty ? (text.split(separator:"\n").first.map(String.init) ?? L10n.t("无标题日记")) : title }
}

public struct EntrySummary: Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var title: String
    public var preview: String
    public var notebook: String
    public var mood: String
    public var tags: [String]
    public var favorite: Bool
    public var deletedAt: Date?
    public var hasPhotos: Bool
    public var weather: WeatherSnapshot?
}

public struct EntryVersion: Identifiable, Sendable {
    public var id: UUID
    public var savedAt: Date
    public var entry: DiaryEntry
}

public struct DiaryPreferences: Codable, Equatable, Sendable {
    public var fontSize: Double = 18
    public var lineSpacing: Double = 10
    public var serif: Bool = true
    public var appearance: String = "system"
    public var idleMinutes: Int = 5
    public var lockOnDeactivate: Bool = false
    public var weatherEnabled: Bool = false
    public var autoBackup: Bool = true
    public var backupRetention: Int = 30
    public var reminderEnabled: Bool = false
    public var reminderHour: Int = 21
    public var reminderMinute: Int = 0
    public var notebooks: [String] = [L10n.t("生活碎片"), L10n.t("在路上"), L10n.t("慢慢成长")]
    public var lastEntry: UUID?
    public init() {}
}

public struct VaultHeader: Codable, Sendable {
    public var version: Int = 1
    public var id: UUID
    public var kdf: String = "argon2id13-64MiB-3"
    public var salt: Data
    public var passwordWrap: Data
    public var recoveryWrap: Data
}

public struct BackupManifest: Codable, Sendable {
    public var version: Int = 1
    public var vaultID: UUID
    public var createdAt: Date
    public var files: [String: String]
}

public struct BackupInfo: Identifiable, Sendable {
    public let url: URL
    public var id: URL { url }
    public let date: Date
}
