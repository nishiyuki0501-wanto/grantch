import Foundation

public enum RiskAnalyzer {
    public static func analyze(command: String, cwd: String) -> (level: RiskLevel, reasons: [String]) {
        // Escaped spaces (`Application\ Support`) would otherwise defeat path matches.
        let value = command.lowercased().replacingOccurrences(of: "\\ ", with: " ")
        var score = 0
        var reasons: [String] = []

        func flag(_ points: Int, _ reason: String) {
            score = max(score, points)
            reasons.append(reason)
        }

        switch removalFlags(in: value) {
        case .recursiveForce: flag(4, "ファイルを再帰的に削除します")
        case .recursive: flag(3, "ファイルを再帰的に削除します")
        case nil: break
        }
        let shell = #"(sudo(\s+-\S+)*\s+)?(env(\s+\S+=\S*)*\s+)?(\S*/)?(sh|bash|zsh|dash|ksh|fish)\b"#
        if value.range(of: #"\|\s*"# + shell, options: .regularExpression) != nil
            || value.range(of: #"<\(\s*(curl|wget)\b"#, options: .regularExpression) != nil
            || value.range(of: #"\b(sh|bash|zsh)\s+-c\s+["']?\$\(\s*(curl|wget)\b"#, options: .regularExpression) != nil {
            flag(4, "受け取った内容をシェルで実行します")
        }
        // Editing these can remove Grantch's hooks, change what agents may do
        // without asking, or run code at the next login, shell start, or commit.
        let protectedFiles = [
            ".claude/settings", ".claude.json", ".codex", ".gemini", ".ssh", ".zshrc", ".zprofile",
            ".zshenv", ".bashrc", ".bash_profile", ".profile", ".git/hooks"
        ]
        let protectedPaths = ["application support/grantch", "grantch-hook", "launchagents", "launchdaemons"]
        if protectedFiles.contains(where: { containsPathComponent(value, $0) }) || protectedPaths.contains(where: value.contains) {
            flag(4, "エージェント・承認フック・ログイン時の設定を変更する可能性があります")
        }
        if value.contains("git push") && (value.contains("--force") || value.contains(" -f")) {
            flag(4, "Git履歴を強制的に上書きします")
        }
        if value.contains("drop table") || value.contains("truncate table") || value.contains("drop database") {
            flag(4, "データベースを破壊する操作です")
        }
        if value.contains("sudo ") || value.hasPrefix("sudo") {
            flag(4, "管理者権限を要求します")
        }
        if value.contains(".env") || value.contains("id_rsa") || value.contains("private_key") {
            flag(4, "認証情報へアクセスする可能性があります")
        }
        if value.contains("deploy") || value.contains("publish") || value.contains("production") {
            flag(3, "外部環境を変更する可能性があります")
        }
        if value.contains("curl ") || value.contains("wget ") || value.contains("ssh ") || value.contains("scp ") {
            flag(2, "ネットワークへ接続します")
        }
        if value.contains(" > ") || value.contains(" >> ") || value.contains("chmod ") || value.contains("chown ") {
            flag(2, "ファイルまたは権限を変更します")
        }
        if value.contains("npm test") || value.contains("swift test") || value.contains("git status") {
            score = max(score, 1)
        }

        let level: RiskLevel = switch score {
        case 4: .critical
        case 3: .high
        case 2: .medium
        default: .low
        }
        return (level, reasons.isEmpty ? ["既知の高危険操作には一致しません"] : reasons)
    }

    /// Matches `name` only where a path component starts, so `.profile`
    /// matches `~/.profile` but not `src/user.profile.ts`.
    static func containsPathComponent(_ value: String, _ name: String) -> Bool {
        var searchStart = value.startIndex
        while let range = value.range(of: name, range: searchStart..<value.endIndex) {
            if range.lowerBound == value.startIndex || "/ \t\"'=~:".contains(value[value.index(before: range.lowerBound)]) {
                return true
            }
            searchStart = value.index(after: range.lowerBound)
        }
        return false
    }

    enum Removal { case recursive, recursiveForce }

    /// Finds `rm` invocations however their flags are written: `-rf`,
    /// `-r -f`, `-Rf`, `--recursive --force`.
    static func removalFlags(in value: String) -> Removal? {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ";&|()`"))
        // `\rm`, `'rm'`, and `"rm"` all run rm.
        let tokens = value.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\\\"'")) }
            .filter { !$0.isEmpty }
        var result: Removal?
        for (index, token) in tokens.enumerated() where token == "rm" || token.hasSuffix("/rm") {
            var recursive = false
            var force = false
            for flag in tokens[(index + 1)...] {
                guard flag.hasPrefix("-"), flag != "--" else { break }
                if flag == "--recursive" { recursive = true }
                else if flag == "--force" { force = true }
                else if !flag.hasPrefix("--") {
                    recursive = recursive || flag.contains("r")
                    force = force || flag.contains("f")
                }
            }
            if recursive && force { return .recursiveForce }
            if recursive { result = .recursive }
        }
        return result
    }
}
