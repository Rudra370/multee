import Foundation

// Multee patch (see Package.swift): resolve the Highlightr resource bundle from the app's
// `Contents/Resources/` before falling back to SwiftPM's `Bundle.module`.
//
// SwiftPM generates `Bundle.module` to check only `Bundle.main.bundleURL/<bundle>` (the .app root)
// and the absolute build-time path. In a distributed, code-signed `.app` the bundle must live in
// `Contents/Resources/` (nothing is allowed at the .app root without breaking the signature), so
// the generated accessor's candidates don't exist on a user's machine and it `fatalError`s. We look
// in `Bundle.main.resourceURL` (= Contents/Resources) first; `.module` remains the fallback so
// non-app contexts (tests, `swift run`, the dev build's local build path) keep working unchanged.
extension Bundle {
    static let highlightrResources: Bundle = {
        let bundleName = "Highlightr_Highlightr.bundle"
        if let resourceURL = Bundle.main.resourceURL,
           let bundle = Bundle(url: resourceURL.appendingPathComponent(bundleName)) {
            return bundle
        }
        return .module
    }()
}
