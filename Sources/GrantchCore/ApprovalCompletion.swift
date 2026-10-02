import Foundation

/// A lifecycle notification only dismisses a pending request; it never grants
/// permission. IDs take precedence over command matching to isolate parallel calls.
public struct ApprovalCompletion: Codable, Sendable {
    public let type: String
    public let agent: String
    public let sessionId: String
    public let toolUseId: String?
    public let turnId: String?
    public let toolName: String?
    public let toolInput: [String: JSONValue]?
    public let sessionEnded: Bool
    /// `Stop` means the main agent finished responding. Background subagents
    /// can still be waiting on a decision, so it does not end their requests.
    public let turnEnded: Bool
    public let observedAt: Date

    public init(data: Data, source: String?, now: Date = Date()) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = object["session_id"] as? String, !session.isEmpty,
              let event = object["hook_event_name"] as? String,
              ["PostToolUse", "PostToolUseFailure", "Stop", "SessionEnd"].contains(event) else {
            throw GrantchError.invalidInput
        }
        type = "completed"
        agent = source ?? (object["turn_id"] == nil ? "claude-code" : "codex")
        sessionId = session
        toolUseId = object["tool_use_id"] as? String
        turnId = object["turn_id"] as? String
        toolName = object["tool_name"] as? String
        if let input = object["tool_input"] as? [String: Any] {
            toolInput = try JSONDecoder().decode([String: JSONValue].self, from: JSONSerialization.data(withJSONObject: input))
        } else { toolInput = nil }
        sessionEnded = event == "SessionEnd"
        turnEnded = event == "Stop"
        observedAt = now
    }

    public func matches(_ request: ApprovalRequest) -> Bool {
        guard type == "completed", agent == request.agent, sessionId == request.sessionId,
              request.createdAt <= observedAt else { return false }
        if let turnId, let requestTurn = request.turnId, turnId != requestTurn { return false }
        if sessionEnded { return true }
        if turnEnded { return request.subagentId == nil }
        if let toolUseId, let requestID = request.toolUseId { return toolUseId == requestID }
        guard let toolName, toolName == request.toolName, let toolInput else { return false }
        return ToolSummary.describe(toolName: toolName, input: toolInput) == request.command
    }
}
