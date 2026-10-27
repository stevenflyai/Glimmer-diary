// swift-tools-version: 6.0
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let package = Package(
    name: "Shiguang",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Shiguang", targets: ["Shiguang"])],
    targets: [
        .target(name: "CSQLCipher", publicHeadersPath: "include", cSettings: [
            .define("SQLITE_HAS_CODEC"), .define("SQLITE_TEMP_STORE", to: "2"),
            .define("SQLITE_EXTRA_INIT", to: "sqlcipher_extra_init"),
            .define("SQLITE_EXTRA_SHUTDOWN", to: "sqlcipher_extra_shutdown"),
            .define("SQLCIPHER_CRYPTO_CC"), .define("SQLITE_THREADSAFE", to: "1"),
            .define("SQLITE_ENABLE_FTS5"), .define("SQLITE_DQS", to: "0"), .define("NDEBUG"),
            .unsafeFlags(["-fno-modules"])
        ], linkerSettings: [.linkedFramework("Security")]),
        .target(name: "CVaultCrypto", publicHeadersPath: "include", cSettings: [
            .headerSearchPath("sodium")
        ], linkerSettings: [.unsafeFlags([root + "/Vendor/libsodium.a"])]),
        .target(name: "DiaryCore", dependencies: ["CSQLCipher", "CVaultCrypto"],resources:[.process("Resources")]),
        .executableTarget(name: "Shiguang", dependencies: ["DiaryCore"]),
        .executableTarget(name: "VaultChecks", dependencies: ["DiaryCore"], path: "Tests/DiaryCoreTests")
    ], swiftLanguageModes: [.v5]
)
