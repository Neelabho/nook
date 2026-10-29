import Foundation

/// Where an app bundle counts as "installed" (for launch at login): /Applications or ~/Applications.
public enum InstallLocation {
    /// The user's real home folder. Inside the App Sandbox, `homeDirectoryForCurrentUser` and
    /// `NSHomeDirectory()` return the app's container, so ~/Applications would never match.
    public static var realHomeDirectory: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    public static func isInstalled(_ bundleURL: URL, home: URL = realHomeDirectory) -> Bool {
        guard bundleURL.pathExtension == "app" else { return false }
        let parent = bundleURL.deletingLastPathComponent().standardizedFileURL.path
        let userApps = home.appendingPathComponent("Applications").standardizedFileURL.path
        return parent == "/Applications" || parent == userApps
    }
}
