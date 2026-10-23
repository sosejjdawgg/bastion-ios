// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BastionCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "BastionCore", targets: ["BastionCore"])],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.7.6")
    ],
    targets: [
        .target(name: "BastionCore", dependencies: ["SwiftSoup"]),
        .testTarget(name: "BastionCoreTests", dependencies: ["BastionCore"], resources: [.copy("Fixtures")])
    ]
)
