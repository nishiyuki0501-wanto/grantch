import Foundation

/// Opt-in record of every bridge invocation, for answering the first question
/// any "Grantch did not appear" report raises: did the CLI call the hook at all?
///
/// Enabled by creating the flag file, so it can be turned on for interfaces
/// that pass no environment of their own (an IDE sidecar, a sandboxed helper).
/// Entries include hook payloads, so commands and paths end up in the file;
/// it is kept readable by the user only.
public enum HookLog {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Grantch")
    }

    public static var flagURL: URL { directory.appendingPathComponent("debug-hook-log") }
    public static var fileURL: URL { directory.appendingPathComponent("log/hook.log") }

    public static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: flagURL.path)
    }

    public static func append(_ message: String) {
        guard isEnabled else { return }
        let manager = FileManager.default
        try? manager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // A diagnostic must not grow without bound on a machine left running.
        if let size = try? manager.attributesOfItem(atPath: fileURL.path)[.size] as? Int, size > 1_000_000 {
            try? manager.removeItem(at: fileURL)
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) pid=\(ProcessInfo.processInfo.processIdentifier) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            manager.createFile(atPath: fileURL.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }
}
