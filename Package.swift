// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "mdv",
    platforms: [.macOS(.v14)],
    dependencies: [
        // swift-markdown has no semver tags; pin to the swift-6.4.0-RELEASE commit.
        .package(
            url: "https://github.com/swiftlang/swift-markdown.git",
            revision: "bc55d614bc8608d74cdc18d3aa6413bd8661e444"
        ),
        // tree-sitter grammars + highlight queries (prebuilt xcframework) for code blocks.
        .package(url: "https://github.com/CodeEditApp/CodeEditLanguages.git", from: "0.1.21"),
    ],
    targets: [
        .executableTarget(
            name: "mdv",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "CodeEditLanguages", package: "CodeEditLanguages"),
            ],
            path: "Sources/mdv"
        ),
    ]
)
