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
        let summary = args["CommandLine"]?.stringValue
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
}
