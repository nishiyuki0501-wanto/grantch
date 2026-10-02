import Foundation

public enum ClaudeOutput {
    public static func data(for response: ApprovalResponse, request: ApprovalRequest) throws -> Data {
        if request.agent == "antigravity" {
            return try JSONSerialization.data(
                withJSONObject: AntigravityOutput.payload(for: response.decision),
                options: [.sortedKeys]
            )
        }
        var decision: [String: Any] = [:]
        switch response.decision {
        case .native: return Data("{}".utf8)
        case .allowOnce:
            decision["behavior"] = "allow"
        case .allowSession:
            decision["behavior"] = "allow"
            // Only the suggestion the panel showed is applied, and only for
            // this session, whatever destination Claude Code proposed.
            if let suggestion = request.sessionSuggestion?.suggestion {
                var update: [String: Any] = ["type": suggestion.type, "behavior": "allow", "destination": "session"]
                if let rules = suggestion.rules {
                    let encoded = try JSONEncoder().encode(rules)
                    update["rules"] = try JSONSerialization.jsonObject(with: encoded)
                }
                decision["updatedPermissions"] = [update]
            }
        case .deny:
            decision = ["behavior": "deny", "message": "Denied by the user in Grantch", "interrupt": false]
        case .denyAndStop:
            decision = ["behavior": "deny", "message": "Denied by the user in Grantch"]
            if request.agent == "claude-code" {
                decision["interrupt"] = true
            }
        }
        let output: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decision
            ]
        ]
        return try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
    }
}

public enum AntigravityOutput {
    /// Antigravity's `PreToolUse` gate is the only decision Grantch controls:
    /// the CLI's own permission check runs separately and no response field can
    /// satisfy it, so Grantch is meant to run Antigravity with
    /// `--dangerously-skip-permissions`, where this hook is the only gate.
    ///
    /// That makes "ask" unusable as a hand-back — the CLI has no prompt left to
    /// fall back to and would execute the tool call unattended. Anything short
    /// of an explicit approval therefore denies.
    public static func payload(for decision: ApprovalDecision) -> [String: Any] {
        switch decision {
        case .allowOnce, .allowSession:
            return ["decision": "allow", "reason": "Approved by the user in Grantch"]
        case .deny, .denyAndStop:
            return ["decision": "deny", "reason": "Denied by the user in Grantch"]
        case .native:
            return ["decision": "deny", "reason": "Grantch could not confirm an approval"]
        }
    }
}
