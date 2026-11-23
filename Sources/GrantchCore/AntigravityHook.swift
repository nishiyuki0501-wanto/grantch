import Foundation

/// Antigravity's documented PreToolUse contract is camelCase, not Claude's
/// PermissionRequest contract. The installer passes the event explicitly.
public struct AntigravityHookInput: Decodable, Sendable {
    public struct ToolCall: Decodable, Sendable {
        public let name: String
        public let args: [String: JSONValue]
    }
    public let conversationId: String
    public let workspacePaths: [String]?
    public let stepIdx: Int
    public let toolCall: ToolCall
}

public extension ApprovalRequest {
    init(antigravity input: AntigravityHookInput, now: Date = Date()) throws {
        guard !input.conversationId.isEmpty, input.stepIdx >= 0 else { throw GrantchError.invalidInput }
        let args = input.toolCall.args
        let workingDirectory = args["Cwd"]?.stringValue ?? input.workspacePaths?.first ?? ""
        // Show the actual operation, not only an agent-authored description.
        let mcp: String? = Self.mcpSummary(toolName: input.toolCall.name, args: args)
        let summary: String = args["CommandLine"]?.stringValue
            ?? mcp
            ?? args["TargetFile"]?.stringValue.map { "\(input.toolCall.name) \($0)" }
            ?? args["Target"]?.stringValue.map { "\(args["Action"]?.stringValue ?? input.toolCall.name) \($0)" }
            ?? (args.isEmpty ? input.toolCall.name : "\(input.toolCall.name) \(ToolSummary.canonicalJSON(.object(args)))")
        let analysis = RiskAnalyzer.analyze(command: summary, cwd: workingDirectory)
        protocolVersion = 1
        id = UUID().uuidString
        agent = "antigravity"
        sessionId = input.conversationId
        cwd = workingDirectory
        project = workingDirectory.isEmpty ? "Antigravity" : URL(fileURLWithPath: workingDirectory).lastPathComponent
        toolName = input.toolCall.name
        command = summary
        risk = analysis.level
        riskReasons = analysis.reasons
        createdAt = now
        expiresAt = now.addingTimeInterval(300)
        permissionSuggestions = nil
        toolUseId = String(input.stepIdx)
        turnId = nil
        detail = nil
        subagentId = nil
    }

    /// MCP calls are shown as `server/tool` followed by the full arguments.
    private static func mcpSummary(toolName: String, args: [String: JSONValue]) -> String? {
        guard toolName == AntigravityTools.mcp,
              let server = args["ServerName"]?.stringValue,
              let tool = args["ToolName"]?.stringValue else { return nil }
        let arguments = args["Arguments"].map { " " + ToolSummary.canonicalJSON($0) } ?? ""
        return "mcp \(server)/\(tool)\(arguments)"
    }
}

public enum AntigravityTools {
    /// The name Antigravity gives every MCP tool call in `PreToolUse`
    /// (agy 1.5.15); the server and tool are in `ServerName` and `ToolName`.
    public static let mcp = "call_mcp_tool"
    /// Tools routed to Grantch: commands, file changes, explicit permission
    /// requests and MCP calls. Read-only tools are left to Antigravity.
    public static let approvalMatcher =
        "^(run_command|write_to_file|replace_file_content|multi_replace_file_content|ask_permission|\(mcp))$"
}
