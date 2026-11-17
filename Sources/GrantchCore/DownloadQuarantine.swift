import Darwin
import Foundation

public enum DownloadQuarantine {
    /// Browser downloads set `com.apple.quarantine` on the app, and copying the
    /// bridge out of that app keeps the flag. Gatekeeper does not treat the
    /// standalone binary as the notarized app, and a CLI hook has no terminal
    /// in which to approve it, so the process is killed. Nothing then reaches
    /// the notch, including auto-approval.
    public static func clear(at url: URL) {
        _ = removexattr(url.path, "com.apple.quarantine", 0)
    }

    public static func clearInstalledBridge(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        clear(at: home.appendingPathComponent("Library/Application Support/Grantch/bin/grantch-hook"))
    }
}
