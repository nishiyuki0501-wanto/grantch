import Darwin
import Foundation

/// Messages are Japanese, or English when macOS prefers English over Japanese,
/// matching how the app picks its language. `GRANTCH_LANG=ja|en` overrides it.
let usesEnglish: Bool = {
    if let forced = ProcessInfo.processInfo.environment["GRANTCH_LANG"] { return forced.hasPrefix("en") }
    return Bundle.preferredLocalizations(from: ["ja", "en"], forPreferences: Locale.preferredLanguages).first == "en"
}()

func t(_ japanese: String, _ english: String) -> String { usesEnglish ? english : japanese }

let appName = t("にゃんこのスタミナ", "Nyanko no Stamina")
/// The name as it reads inside a sentence.
let quotedAppName = t("「にゃんこのスタミナ」", "Nyanko no Stamina")

enum ConfigError: LocalizedError {
    case usage
    case invalidSettings(String)
    case bridgeNotFound(String)
    case installFailed(String)
    case noSupportedCLI

    var errorDescription: String? {
        switch self {
        case .usage: t("使い方: grantch-config install [ブリッジのパス] | uninstall", "Usage: grantch-config install [bridge-path] | uninstall")
        case .invalidSettings(let path): t("フック設定が JSON オブジェクトではありません: \(path)", "Hook settings must contain a JSON object: \(path)")
        case .bridgeNotFound(let path): t("grantch-hook が見つかりません: \(path)", "grantch-hook not found at \(path)")
        case .installFailed(let message): message
        case .noSupportedCLI: t(
            "~/.claude、~/.codex、~/.gemini のどれも見つかりません。Claude Code、Codex CLI、Antigravity CLI のいずれかを一度起動してから、もう一度インストールしてください。",
            "No ~/.claude, ~/.codex, or ~/.gemini directory found. Run Claude Code, Codex CLI, or Antigravity CLI once, then install again."
        )
        }
    }
}

let manager = FileManager.default
let home = ProcessInfo.processInfo.environment["GRANTCH_CONFIG_HOME"].map { URL(fileURLWithPath: $0) } ?? manager.homeDirectoryForCurrentUser
let claudeSettingsURL = home.appendingPathComponent(".claude/settings.json")
let codexHooksURL = home.appendingPathComponent(".codex/hooks.json")
let antigravityHooksURL = home.appendingPathComponent(".gemini/config/hooks.json")
let installDirectory = home.appendingPathComponent("Library/Application Support/Grantch/bin")
let installedBridge = installDirectory.appendingPathComponent("grantch-hook")

func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

@MainActor func commandValue() -> String { shellQuote(installedBridge.path) }

@MainActor func loadObject(at url: URL) throws -> [String: Any] {
    guard manager.fileExists(atPath: url.path) else { return [:] }
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    guard let settings = object as? [String: Any] else { throw ConfigError.invalidSettings(url.path) }
    return settings
}

/// One backup per file per run keeps the state from before Grantch touched it,
/// without a copy for every hook event written to the same file.
var backedUpPaths: Set<String> = []

/// Follows symlinks even when the final target does not exist yet, so a
/// dangling dotfile link is filled in rather than replaced by a regular file.
@MainActor func resolvedTarget(of url: URL) -> URL {
    var current = url
    for _ in 0..<32 {
        guard let destination = try? manager.destinationOfSymbolicLink(atPath: current.path) else { return current }
        // Relative targets are relative to the link's real directory, which
        // may itself be reached through a symlink.
        let directory = current.deletingLastPathComponent().resolvingSymlinksInPath()
        current = URL(fileURLWithPath: destination, relativeTo: directory).standardizedFileURL
    }
    return current
}

@MainActor func save(_ object: [String: Any], to link: URL) throws {
    // Write through a symlinked settings file (dotfile managers) instead of
    // replacing the link with a regular file.
    let url = resolvedTarget(of: link)
    try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let existingMode = (try? manager.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber
    // A file this run creates has nothing of the user's to back up later.
    if !manager.fileExists(atPath: url.path) { backedUpPaths.insert(url.path) }
    if manager.fileExists(atPath: url.path), backedUpPaths.insert(url.path).inserted {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        // Beside the path the user knows rather than inside a dotfiles
        // repository the link points into, and private: settings can hold tokens.
        let backup = link.appendingPathExtension("grantch-backup-\(formatter.string(from: Date()))-\(UUID().uuidString)")
        guard manager.createFile(atPath: backup.path, contents: try Data(contentsOf: url), attributes: [.posixPermissions: 0o600]) else {
            throw ConfigError.installFailed(t("バックアップを書き込めません: \(backup.path)", "Could not write backup \(backup.path)"))
        }
        print(t("バックアップ: \(backup.path)", "Backup: \(backup.path)"))
    }
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try data.write(to: url, options: .atomic)
    chmod(url.path, existingMode.map { mode_t($0.uint16Value) } ?? 0o600)
}

@MainActor func installHook(
    at url: URL,
    matcher: String?,
    event: String = "PermissionRequest",
    source: String? = nil,
    timeout: Int = 330
) throws -> Bool {
    var root = try loadObject(at: url)
    if let hooks = root["hooks"], !(hooks is [String: Any]) { throw ConfigError.invalidSettings(url.path) }
    var hooks = root["hooks"] as? [String: Any] ?? [:]
    if let groups = hooks[event], !(groups is [[String: Any]]) { throw ConfigError.invalidSettings(url.path) }
    var permissionRequests = hooks[event] as? [[String: Any]] ?? []
    let expectedCommand = commandValue() + (event == "PermissionRequest" ? "" : " --completed --source " + (source ?? "claude-code"))
    let alreadyInstalled = permissionRequests.contains { group in
        (group["hooks"] as? [[String: Any]])?.contains { $0["command"] as? String == expectedCommand } == true
    }
    guard !alreadyInstalled else { return false }

    var handler: [String: Any] = ["type": "command", "command": expectedCommand, "timeout": timeout]
    if event == "PermissionRequest" { handler["statusMessage"] = t("\(appName)で承認待ち", "Waiting for approval in \(appName)") }
    var group: [String: Any] = ["hooks": [handler]]
    if let matcher { group["matcher"] = matcher }
    permissionRequests.append(group)
    hooks[event] = permissionRequests
    root["hooks"] = hooks
    try save(root, to: url)
    return true
}

@MainActor func removeHook(at url: URL) throws -> Bool {
    var root = try loadObject(at: url)
    guard var hooks = root["hooks"] as? [String: Any] else { return false }
    let expectedCommand = commandValue()
    func isOurs(_ handler: [String: Any]) -> Bool {
        let command = handler["command"] as? String ?? ""
        return command == expectedCommand || ["claude-code", "codex"].contains {
            command == expectedCommand + " --completed --source " + $0
        }
    }
    var removed = false
    for event in Array(hooks.keys) {
        guard let groups = hooks[event] as? [[String: Any]] else { continue }
        var updatedGroups: [[String: Any]] = []
        var removedHere = false
        for group in groups {
            // Groups without a Grantch handler, including empty ones, stay as they are.
            guard let handlers = group["hooks"] as? [[String: Any]], handlers.contains(where: isOurs) else {
                updatedGroups.append(group)
                continue
            }
            removedHere = true
            let retained = handlers.filter { !isOurs($0) }
            if !retained.isEmpty {
                var updated = group
                updated["hooks"] = retained
                updatedGroups.append(updated)
            }
        }
        guard removedHere else { continue }
        removed = true
        if updatedGroups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = updatedGroups }
    }
    guard removed else { return false }
    if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
    try save(root, to: url)
    return true
}

@MainActor func configureAntigravity(remove: Bool = false) throws -> Bool {
    var root = try loadObject(at: antigravityHooksURL)
    let name = "grantch-approval"
    let command = commandValue() + " --source antigravity"
    if remove {
        guard let hook = root[name] as? [String: Any],
              let groups = hook["PreToolUse"] as? [[String: Any]],
              groups.count == 1,
              let handlers = groups[0]["hooks"] as? [[String: Any]],
              handlers.count == 1, handlers[0]["command"] as? String == command else { return false }
        root.removeValue(forKey: name)
    } else {
        let definition: [String: Any] = ["PreToolUse": [[
            "matcher": "^(run_command|write_to_file|replace_file_content|multi_replace_file_content|ask_permission)$",
            "hooks": [["type": "command", "command": command, "timeout": 330]]
        ]]]
        if let existing = root[name] {
            if NSDictionary(dictionary: definition).isEqual(existing) { return false }
            // An earlier Grantch definition is replaced; anything else is not ours to touch.
            let groups = (existing as? [String: Any])?["PreToolUse"] as? [[String: Any]] ?? []
            let isOurs = groups.contains { group in
                (group["hooks"] as? [[String: Any]])?.contains { $0["command"] as? String == command } == true
            }
            guard isOurs else { throw ConfigError.invalidSettings(t("同じ名前の別のフックがあります: ", "Existing unrelated hook named ") + name) }
        }
        root[name] = definition
    }
    try save(root, to: antigravityHooksURL)
    return true
}

@MainActor func install(sourcePath: String?) throws {
    // argv[0] is only a bare name when the installer is run through PATH.
    let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    let defaultSource = executable.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("grantch-hook").path
    let source = sourcePath ?? defaultSource
    guard manager.isExecutableFile(atPath: source) else { throw ConfigError.bridgeNotFound(source) }
    // Only CLIs that have been run are configured, so no config files appear
    // for tools the user does not have.
    func isPresent(_ directory: String) -> Bool {
        manager.fileExists(atPath: home.appendingPathComponent(directory).path)
    }
    let hasClaude = isPresent(".claude"), hasCodex = isPresent(".codex"), hasAntigravity = isPresent(".gemini")
    guard hasClaude || hasCodex || hasAntigravity else { throw ConfigError.noSupportedCLI }

    try manager.createDirectory(at: installDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    chmod(installDirectory.path, 0o700)
    // Stage and rename so the hook command never points at a missing file.
    let staged = installDirectory.appendingPathComponent(".grantch-hook-\(UUID().uuidString)")
    try manager.copyItem(at: URL(fileURLWithPath: source), to: staged)
    chmod(staged.path, 0o755)
    guard rename(staged.path, installedBridge.path) == 0 else {
        let message = String(cString: strerror(errno))
        try? manager.removeItem(at: staged)
        throw ConfigError.installFailed(t("\(installedBridge.path) をインストールできません: \(message)", "Could not install \(installedBridge.path): \(message)"))
    }

    // Antigravity first: it is the one that can refuse (an unrelated hook with
    // our name), and refusing before the others are written avoids a partial install.
    if hasAntigravity {
        let installed = try configureAntigravity()
        print(installed
            ? t("Antigravity CLI の承認フックをインストールしました。", "Installed Antigravity CLI PreToolUse approval Hook.")
            : t("Antigravity CLI のフックは設定済みです。", "Antigravity CLI Hook was already configured."))
    } else {
        print(t("Antigravity CLI はスキップしました（~/.gemini がありません）。", "Skipped Antigravity CLI: ~/.gemini not found."))
    }
    if hasClaude {
        let installed = try installHook(at: claudeSettingsURL, matcher: ".*")
        for event in ["PostToolUse", "PostToolUseFailure", "Stop", "SessionEnd"] {
            _ = try installHook(
                at: claudeSettingsURL,
                matcher: event.hasPrefix("PostTool") ? ".*" : nil,
                event: event,
                source: "claude-code",
                timeout: 5
            )
        }
        print(installed
            ? t("Claude Code の承認フックをインストールしました。", "Installed Claude Code approval Hook.")
            : t("Claude Code の承認フックは設定済みです。", "Claude Code approval Hook was already configured."))
    } else {
        print(t("Claude Code はスキップしました（~/.claude がありません）。", "Skipped Claude Code: ~/.claude not found."))
    }
    if hasCodex {
        let installed = try installHook(at: codexHooksURL, matcher: nil)
        // Codex caps lifecycle hooks at 3 seconds.
        for event in ["PostToolUse", "Stop", "SessionEnd"] {
            _ = try installHook(at: codexHooksURL, matcher: nil, event: event, source: "codex", timeout: 3)
        }
        print(installed
            ? t("Codex CLI の承認フックをインストールしました。次回の Codex 起動時に、フックの確認と信頼を求められます。", "Installed Codex CLI approval Hook. Codex asks you to review and trust it on its next launch.")
            : t("Codex CLI の承認フックは設定済みです。", "Codex CLI approval Hook was already configured."))
    } else {
        print(t("Codex CLI はスキップしました（~/.codex がありません）。", "Skipped Codex CLI: ~/.codex not found."))
    }
    print(t(
        "実行中の CLI を再起動してください。対応 CLI を追加したときや、\(quotedAppName)を更新したときは、もう一度 install を実行してください。",
        "Restart running CLIs. Run install again after adding a supported CLI or updating \(appName)."
    ))
    // Antigravity checks its own permissions after the pre-tool gate opens, and
    // no hook response can satisfy that check. Grantch is the only gate the
    // user actually sees, so say how to let it be the only gate there is.
    if hasAntigravity {
        print("\n" + t(
            """
            Antigravity の注意: `agy --dangerously-skip-permissions` で起動すると、\(quotedAppName)だけで承認できます。\
            このオプションなしでは、\(quotedAppName)で許可した後にターミナルでもう一度確認されます。\
            このとき\(quotedAppName)が確認するのは run_command、ファイルの書き込み、ask_permission だけで、\
            ほかのツールは確認なしで実行されます。決まらなかった要求（未起動・期限切れ・取り消し）は拒否されます。
            """,
            """
            Antigravity note: start it as `agy --dangerously-skip-permissions` so \(appName) owns the approval. \
            Without that, Antigravity asks again in the terminal after \(appName) says allow. \
            \(appName) then gates only run_command, file writes, and ask_permission; other tools run \
            without asking. An undecided request (not running, expired, cancelled) is denied.
            """
        ))
    }
}

@MainActor func uninstall() throws {
    let claudeRemoved = try removeHook(at: claudeSettingsURL)
    let codexRemoved = try removeHook(at: codexHooksURL)
    _ = try configureAntigravity(remove: true)
    if manager.fileExists(atPath: installedBridge.path) { try manager.removeItem(at: installedBridge) }
    print(claudeRemoved
        ? t("Claude Code から\(quotedAppName)のフックを削除しました。ほかのフックはそのままです。", "Removed \(appName) from Claude Code; other handlers were preserved.")
        : t("Claude Code に\(quotedAppName)のフックはありません。", "No \(appName) hook found in Claude Code."))
    print(codexRemoved
        ? t("Codex CLI から\(quotedAppName)のフックを削除しました。ほかのフックはそのままです。", "Removed \(appName) from Codex CLI; other handlers were preserved.")
        : t("Codex CLI に\(quotedAppName)のフックはありません。", "No \(appName) hook found in Codex CLI."))
}

do {
    guard CommandLine.arguments.count >= 2 else { throw ConfigError.usage }
    switch CommandLine.arguments[1] {
    case "install": try install(sourcePath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil)
    case "uninstall": try uninstall()
    default: throw ConfigError.usage
    }
} catch {
    FileHandle.standardError.write(Data("grantch-config: \(error.localizedDescription)\n".utf8))
    exit(1)
}
