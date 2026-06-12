// swift-tools-version:5.9

// Vendored copy of raspu/Highlightr (MIT, see LICENSE), pinned at 2.2.0.
//
// WHY VENDORED: SwiftPM's generated `Bundle.module` accessor only looks for the resource bundle
// next to `Bundle.main.bundleURL` (the .app *root*) and at the absolute build-machine path baked in
// at compile time. When we package the app into a real macOS `.app`, the resource bundle lives in
// `Contents/Resources/` (the only place a code-signed `.app` allows it), so neither candidate
// resolves on a user's machine → `Bundle.module` hits `fatalError` the instant the editor opens a
// file. We patch the one `Bundle.module` use (see src/classes/BundleResolve.swift) to look in
// `Contents/Resources/` first, which keeps the bundle properly sealed AND findable. Everything else
// is upstream, unchanged.

import PackageDescription

let package = Package(
    name: "Highlightr",
    platforms: [
        .macOS(.v10_13),
        .iOS(.v12),
    ],
    products: [
        .library(name: "Highlightr", targets: ["Highlightr"]),
    ],
    targets: [
        .target(
            name: "Highlightr",
            dependencies: [],
            path: "src",
            exclude: [
                "assets/highlighter/LICENSE",
            ],
            sources: [
                "classes",
            ],
            resources: [
                .process("assets/highlighter/highlight.min.js"),
                .process("assets/styles/."),
            ]
        ),
    ]
)
