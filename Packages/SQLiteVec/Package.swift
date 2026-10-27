// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SQLiteVec",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CSQLiteVec", targets: ["CSQLiteVec"])],
    targets: [.target(name: "CSQLiteVec", publicHeadersPath: "include",
                      cSettings: [.define("SQLITE_CORE"), .define("SQLITE_VEC_STATIC")],
                      linkerSettings: [.linkedLibrary("sqlite3")])]
)
