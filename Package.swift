// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Multee",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
        // Highlightr is vendored (see vendor/Highlightr) so its resource bundle resolves from the
        // app's Contents/Resources — the stock SwiftPM accessor only checks the .app root and the
        // build-machine path, so a distributed .app crashes on file-open. See vendor/Highlightr.
        .package(path: "vendor/Highlightr"),
    ],
    targets: [
        .executableTarget(
            name: "Multee",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Highlightr", package: "Highlightr"),
            ],
            path: "Sources/Multee"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
