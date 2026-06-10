import Foundation

extension Bundle {
    /// The packaged SwiftPM resource bundle (murmur_murmur.bundle), resolved in a
    /// way that works inside a signed .app.
    ///
    /// SwiftPM's generated `Bundle.module` looks only at
    /// `Bundle.main.bundleURL/murmur_murmur.bundle` (the .app root) plus the
    /// build-time directory. The .app root can't hold a loose bundle without
    /// breaking code signing ("unsealed contents present in the bundle root"), and
    /// the build dir doesn't exist on other machines — so `Bundle.module` crashes
    /// on launch anywhere but the build machine. We instead search code-sign-safe
    /// locations under Contents/ and never fatal-error.
    static let appResources: Bundle = {
        let name = "murmur_murmur.bundle"
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent(name),                               // Contents/Resources/
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name), // Contents/MacOS/
            Bundle.main.bundleURL.appendingPathComponent(name),                                  // .app root (SwiftPM default)
        ]
        for url in candidates.compactMap({ $0 }) {
            if let bundle = Bundle(url: url) { return bundle }
        }
        return Bundle.main  // last resort: don't crash; main bundle still localizes
    }()
}

/// Look up a localized string from the app's resource bundle.
func L(_ key: String) -> String {
    Bundle.appResources.localizedString(forKey: key, value: key, table: nil)
}
