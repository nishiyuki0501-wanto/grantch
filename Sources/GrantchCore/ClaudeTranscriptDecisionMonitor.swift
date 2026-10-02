import Foundation

public final class ClaudeTranscriptDecisionMonitor {
    public enum Decision: String, Sendable {
        case allow
        case deny
    }

    private let handle: FileHandle
    private let toolUseID: String
    private var offset: UInt64
    private var pending = Data()
    private var initialDecision: Decision?

    public init?(input: ClaudeHookInput, command: String) {
        guard let path = input.transcriptPath,
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)),
              let end = try? handle.seekToEnd() else { return nil }

        let tailLimit: UInt64 = 1_048_576
        let start = end > tailLimit ? end - tailLimit : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let tail = try? handle.read(upToCount: Int(end - start)) else { return nil }

        let resolvedToolUseID = input.toolUseId
            ?? Self.findToolUseID(in: tail, toolName: input.toolName, command: command)
        guard let resolvedToolUseID else { return nil }

        self.handle = handle
        toolUseID = resolvedToolUseID
        offset = end
        // The terminal may have resolved the call before this hook starts.
        initialDecision = tail.split(separator: 0x0A).compactMap {
            Self.decision(in: Data($0), toolUseID: resolvedToolUseID)
        }.last
    }

    deinit { try? handle.close() }

    public func pollDecision() -> Decision? {
        if let decision = initialDecision { initialDecision = nil; return decision }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let newData = try? handle.readToEnd(),
              !newData.isEmpty else { return nil }
        offset += UInt64(newData.count)
        pending.append(newData)

        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending.prefix(upTo: newline)
            pending.removeSubrange(...newline)
            if let decision = Self.decision(in: Data(line), toolUseID: toolUseID) {
                return decision
            }
        }
        return nil
    }

    private static func findToolUseID(in data: Data, toolName: String, command: String) -> String? {
        for line in data.split(separator: 0x0A).reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for item in content.reversed() where item["type"] as? String == "tool_use" {
                guard item["name"] as? String == toolName,
                      let id = item["id"] as? String else { continue }
                let input = item["input"] as? [String: Any] ?? [:]
                if ToolSummary.describe(toolName: toolName, input: input) == command { return id }
            }
        }
        return nil
    }

    private static func decision(in data: Data, toolUseID: String) -> Decision? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let attachment = object["attachment"] as? [String: Any],
           attachment["toolUseID"] as? String == toolUseID,
           attachment["hookEvent"] as? String == "PermissionRequest",
           let rawDecision = attachment["decision"] as? String {
            return Decision(rawValue: rawDecision)
        }
        // Native terminal decisions do not necessarily emit hook attachments.
        // A correlated tool result (including errors/cancellation) proves the
        // request is no longer pending. This is dismissal, never authorization.
        if let message = object["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]],
           let result = content.first(where: {
               $0["type"] as? String == "tool_result" && $0["tool_use_id"] as? String == toolUseID
           }) {
            return result["is_error"] as? Bool == true ? .deny : .allow
        }
        return nil
    }
}
