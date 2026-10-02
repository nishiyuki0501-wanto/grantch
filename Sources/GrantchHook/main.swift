import Darwin
import Foundation
import GrantchCore

func hookSource() -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--source"), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func nativeFallback() -> Never {
    // Claude Code and Codex read an empty object as "no opinion" and show their
    // own permission UI. Antigravity has no prompt to fall back to when it runs
    // with --dangerously-skip-permissions, and it reads an empty object as a
    // denial anyway, so an undecided request is denied explicitly rather than
    // executing unattended.
    let deniesForAntigravity = hookSource() == "antigravity"
        && !CommandLine.arguments.contains("--completed")
    let payload = deniesForAntigravity
        ? (try? JSONSerialization.data(withJSONObject: AntigravityOutput.payload(for: .native), options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) }
            ?? #"{"decision":"deny","reason":"Grantch could not confirm an approval"}"#
        : "{}"
    HookLog.append("out source=\(hookSource() ?? "claude") payload=\(payload)")
    FileHandle.standardOutput.write(Data((payload + "\n").utf8))
    exit(0)
}

do {
    let inputData = FileHandle.standardInput.readDataToEndOfFile()
    HookLog.append("in source=\(hookSource() ?? "claude") args=\(CommandLine.arguments.dropFirst().joined(separator: " ")) bytes=\(inputData.count) payload=\(String(decoding: inputData.prefix(600), as: UTF8.self))")
    guard !inputData.isEmpty else { nativeFallback() }
    let arguments = CommandLine.arguments
    let source = hookSource()
    if arguments.contains("--completed") {
        let completion = try ApprovalCompletion(data: inputData, source: source)
        let descriptor = try SocketIO.connect(path: SocketPath.current)
        try SocketIO.writeLine(try JSONEncoder.grantch.encode(completion), to: descriptor)
        close(descriptor)
        nativeFallback()
    }
    let request: ApprovalRequest
    let transcriptMonitor: ClaudeTranscriptDecisionMonitor?
    if source == "antigravity" {
        let input = try JSONDecoder().decode(AntigravityHookInput.self, from: inputData)
        request = try ApprovalRequest(antigravity: input)
        transcriptMonitor = nil
    } else {
        let input = try JSONDecoder().decode(ClaudeHookInput.self, from: inputData)
        request = try ApprovalRequest(claude: input)
        transcriptMonitor = request.agent == "claude-code"
            ? ClaudeTranscriptDecisionMonitor(input: input, command: request.command) : nil
    }
    // Shell wrappers can survive cancellation of the CLI. Stop heartbeating if
    // our immediate parent exits, and always enforce the request's own deadline.
    let parentPID = getppid()
    let descriptor = try SocketIO.connect(path: SocketPath.current)
    defer { close(descriptor) }
    try SocketIO.writeLine(try JSONEncoder.grantch.encode(request), to: descriptor)
    var response: ApprovalResponse?
    while response == nil {
        if Date() >= request.expiresAt || getppid() != parentPID || parentPID == 1
            || transcriptMonitor?.pollDecision() != nil { nativeFallback() }
        var status = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
        let result = Darwin.poll(&status, 1, 200)
        if result > 0 && (status.revents & Int16(POLLIN)) != 0 {
            response = try JSONDecoder.grantch.decode(
                ApprovalResponse.self,
                from: SocketIO.readLine(from: descriptor)
            )
        } else if result < 0 || (result > 0 && (status.revents & Int16(POLLHUP | POLLERR | POLLNVAL)) != 0) {
            nativeFallback()
        } else if transcriptMonitor?.pollDecision() != nil {
            nativeFallback()
        } else {
            try SocketIO.writeLine(
                JSONEncoder.grantch.encode(ApprovalHeartbeat(requestId: request.id)),
                to: descriptor
            )
        }
    }
    if transcriptMonitor?.pollDecision() != nil { nativeFallback() }
    guard let response else { nativeFallback() }
    guard response.requestId == request.id else { nativeFallback() }
    let output = try ClaudeOutput.data(for: response, request: request)
    HookLog.append("decided source=\(source ?? "claude") tool=\(request.toolName) decision=\(response.decision.rawValue) payload=\(String(decoding: output, as: UTF8.self))")
    FileHandle.standardOutput.write(output)
    FileHandle.standardOutput.write(Data("\n".utf8))
    exit(0)
} catch {
    // A hook failure must never become an implicit approval. Empty structured
    // output lets Claude Code show its native permission dialog.
    nativeFallback()
}
