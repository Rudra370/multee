// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Multee",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "Multee",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/Multee",
            // Grammar JSON for the native TextMate highlighter (replaced Highlightr's JS engine).
            // build.sh copies the generated Multee_Multee.bundle into Contents/Resources; the bundle
            // is resolved there at runtime (see GrammarBundle) to avoid Bundle.module's distributed-app crash.
            resources: [.copy("TextMate/Grammars")]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
