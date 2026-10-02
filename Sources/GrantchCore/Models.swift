import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    /// Decoding recurses once per level and runs on dispatch worker threads
    /// with small stacks, so CLI-supplied input cannot nest arbitrarily deep.
    /// Deeper input fails to decode, which every caller treats as fail-safe.
    static let maximumDepth = 64

    public init(from decoder: Decoder) throws {
        guard decoder.codingPath.count < Self.maximumDepth else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "JSON nested too deeply"))
        }
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}

public struct PermissionSuggestion: Codable, Sendable, Equatable {
    public let type: String
    public let rules: [JSONValue]?
    public let behavior: String?
    public let destination: String?

    /// The rules this suggestion would grant, as Claude Code writes them
    /// (`Bash(git:*)`, or just `Bash` for the whole tool). Nil when there is
    /// nothing describable to show the user, in which case it is not offered.
    public var ruleSummary: String? {
        guard type == "addRules", behavior == "allow", let rules, !rules.isEmpty else { return nil }
        let parts = rules.map { rule -> String? in
            guard case .object(let fields) = rule, let tool = fields["toolName"]?.stringValue else { return nil }
            guard let content = fields["ruleContent"]?.stringValue, !content.isEmpty else { return tool }
            return "\(tool)(\(content))"
        }
        guard parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }.joined(separator: ", ")
    }
}

public struct ClaudeHookInput: Codable, Sendable, Equatable {
    public let sessionId: String
    public let turnId: String?
    public let agentId: String?
    public let agentType: String?
    public let transcriptPath: String?
    public let cwd: String
    public let permissionMode: String?
    public let hookEventName: String
    public let model: String?
    public let toolName: String
    public let toolInput: [String: JSONValue]
    public let toolUseId: String?
    public let permissionSuggestions: [PermissionSuggestion]?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case turnId = "turn_id"
        case agentId = "agent_id"
        case agentType = "agent_type"
        case transcriptPath = "transcript_path"
        case cwd
        case permissionMode = "permission_mode"
        case hookEventName = "hook_event_name"
        case model
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case toolUseId = "tool_use_id"
        case permissionSuggestions = "permission_suggestions"
    }
}

public enum RiskLevel: String, Codable, Sendable, CaseIterable {
    case low, medium, high, critical
}

public struct ApprovalRequest: Codable, Identifiable, Sendable, Equatable {
    public let protocolVersion: Int
    public let id: String
    public let agent: String
    public let sessionId: String
    public let cwd: String
    public let project: String
    public let toolName: String
    public let command: String
    public let risk: RiskLevel
    public let riskReasons: [String]
    public let createdAt: Date
    public let expiresAt: Date
    public let permissionSuggestions: [PermissionSuggestion]?
    public let toolUseId: String?
    public let turnId: String?
    /// The agent's own description of the call. Shown only as secondary text,
    /// never in place of the actual input.
    public let detail: String?
    /// Set for requests raised inside a Claude Code subagent.
    public let subagentId: String?

    public init(claude input: ClaudeHookInput, now: Date = Date()) throws {
        guard input.hookEventName == "PermissionRequest" else {
            throw GrantchError.unsupportedEvent(input.hookEventName)
        }
        let command = ToolSummary.describe(toolName: input.toolName, input: input.toolInput)
        let analysis = RiskAnalyzer.analyze(command: command, cwd: input.cwd)
        protocolVersion = 1
        id = UUID().uuidString
        agent = input.turnId == nil ? "claude-code" : "codex"
        sessionId = input.sessionId
        cwd = input.cwd
        project = URL(fileURLWithPath: input.cwd).lastPathComponent
        toolName = input.toolName
        self.command = command
        risk = analysis.level
        riskReasons = analysis.reasons
        createdAt = now
        expiresAt = now.addingTimeInterval(300)
        permissionSuggestions = input.permissionSuggestions
        toolUseId = input.toolUseId
        turnId = input.turnId
        detail = input.toolInput["description"]?.stringValue
        subagentId = input.agentId
    }

    /// The first permission suggestion that would allow the call, with the
    /// rules it grants. Only Claude Code applies session rules.
    public var sessionSuggestion: (suggestion: PermissionSuggestion, rules: String)? {
        guard agent == "claude-code" else { return nil }
        guard let suggestion = permissionSuggestions?.first(where: { $0.behavior == "allow" }),
              let rules = suggestion.ruleSummary else { return nil }
        return (suggestion, rules)
    }
}

public enum ApprovalDecision: String, Codable, Sendable {
    case allowOnce = "allow_once"
    case allowSession = "allow_session"
    case deny
    case denyAndStop = "deny_and_stop"
    case native = "native"
}

public struct ApprovalResponse: Codable, Sendable {
    public let protocolVersion: Int
    public let requestId: String
    public let decision: ApprovalDecision
    public let decidedAt: Date

    public init(requestId: String, decision: ApprovalDecision, decidedAt: Date = Date()) {
        protocolVersion = 1
        self.requestId = requestId
        self.decision = decision
        self.decidedAt = decidedAt
    }
}

public struct ApprovalHeartbeat: Codable, Sendable {
    public let type: String
    public let requestId: String

    public init(requestId: String) {
        type = "heartbeat"
        self.requestId = requestId
    }
}

public enum GrantchError: LocalizedError {
    case invalidInput
    case unsupportedEvent(String)
    case socket(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .invalidInput: "Invalid hook input"
        case .unsupportedEvent(let event): "Unsupported event: \(event)"
        case .socket(let message): "Socket error: \(message)"
        case .timedOut: "Approval timed out"
        }
    }
}
