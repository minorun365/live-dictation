import Foundation

/// Apps whose windows are never saved, whatever the target. The full-screen record
/// keeps everything on the displays, so apps that show secrets are cut out of it.
/// The list matches bundle ID prefixes and is applied to every capture that covers a
/// whole display.
///
/// A password manager's popup that runs inside a browser (an extension) belongs to
/// the browser window and cannot be cut out here.
enum CaptureExclusion {
    static let bundleIDPrefixes = [
        // Password managers
        "com.1password.",          // 1Password 8
        "com.agilebits.",          // 1Password 7
        "com.apple.Passwords",     // Passwords (macOS 15+)
        "com.apple.keychainaccess",
        "com.bitwarden.desktop",
        "com.dashlane.",
        "com.lastpass.",
        "com.keepersecurity.",
        "in.sinew.Enpass",
        "org.keepassxc.",
        "me.proton.pass",
        // System password and Touch ID prompts
        "com.apple.SecurityAgent",
        "com.apple.coreautha",
        "com.apple.LocalAuthentication",
    ]

    static func isExcluded(bundleID: String) -> Bool {
        !bundleID.isEmpty && bundleIDPrefixes.contains { bundleID.hasPrefix($0) }
    }
}
