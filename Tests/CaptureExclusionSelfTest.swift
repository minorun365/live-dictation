import Foundation

@main
struct CaptureExclusionSelfTest {
    static func main() {
        let excluded = [
            "com.1password.1password",
            "com.agilebits.onepassword7",
            "com.apple.Passwords",
            "com.bitwarden.desktop",
            "com.apple.SecurityAgent",
        ]
        let kept = [
            "com.microsoft.teams2",
            "com.google.Chrome",
            "com.tinyspeck.slackmacgap",
            "com.apple.finder",
            "",
        ]
        for id in excluded where !CaptureExclusion.isExcluded(bundleID: id) {
            print("FAILED: should exclude \(id)"); exit(1)
        }
        for id in kept where CaptureExclusion.isExcluded(bundleID: id) {
            print("FAILED: should keep \(id)"); exit(1)
        }
        print("CaptureExclusionSelfTest passed")
    }
}
