import Foundation

/// The text shown for, risk-checked against, and matched across a tool call.
///
/// Shell tools show their command. Known built-in tools show their name and
/// what they act on, so an edit to `~/.ssh/config` is never presented as a
/// bare `Edit`. Every other tool (MCP servers, new built-ins) shows its whole
/// input, since any field might matter. An agent-authored `description` is
/// never shown in place of the actual input.
public enum ToolSummary {
    static let shellTools: Set<String> = ["Bash", "PowerShell", "exec_command", "shell", "local_shell"]
    /// Built-ins whose remaining fields (file contents, edit text, fetch
    /// prompts) do not change what they touch.
    static let targetTools: Set<String> = [
        "Read", "Write", "Edit", "MultiEdit", "NotebookEdit", "Glob", "Grep", "LS", "WebFetch", "WebSearch"
    ]
    static let targetKeys = ["file_path", "notebook_path", "url", "query", "pattern", "path"]

    public static func describe(toolName: String, input: [String: JSONValue]) -> String {
        let command = text(input["command"]) ?? text(input["cmd"])
        if shellTools.contains(toolName), let command {
            var markers: [String] = []
            if input["dangerouslyDisableSandbox"] == .bool(true) { markers.append("[sandbox off]") }
            if input["with_escalated_permissions"] == .bool(true)
                || input["sandbox_permissions"]?.stringValue?.contains("escalat") == true {
                markers.append("[escalated]")
            }
            var line = (markers + [command]).joined(separator: " ")
            if let directory = text(input["workdir"]) ?? text(input["cwd"]) { line += "  [workdir: \(directory)]" }
            return line
        }
        // A patch carries its own file paths.
        if toolName == "apply_patch", let command { return "\(toolName) \(command)" }
        if targetTools.contains(toolName) {
            let targets = targetKeys.compactMap { text(input[$0]) }
            if !targets.isEmpty { return ([toolName] + targets).joined(separator: " ") }
        }
        return input.isEmpty ? toolName : "\(toolName) \(canonicalJSON(.object(input)))"
    }

    public static func describe(toolName: String, input: [String: Any]) -> String {
        describe(toolName: toolName, input: jsonValues(input))
    }

    /// Converts a JSONSerialization object so both decoding paths describe a
    /// call identically.
    public static func jsonValues(_ object: [String: Any]) -> [String: JSONValue] {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let values = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return [:] }
        return values
    }

    /// A string, or an argv-style array of strings joined with spaces.
    static func text(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let string): string
        case .array(let items):
            items.allSatisfy { $0.stringValue != nil } && !items.isEmpty
                ? items.compactMap(\.stringValue).joined(separator: " ") : nil
        default: nil
        }
    }

    /// Sorted-key JSON so the same input always yields the same text.
    public static func canonicalJSON(_ value: JSONValue) -> String {
        switch value {
        case .string(let string): quoted(string)
        case .number(let number):
            number.rounded() == number && abs(number) < 1e15 ? String(Int64(number)) : String(number)
        case .bool(let bool): bool ? "true" : "false"
        case .null: "null"
        case .array(let items): "[" + items.map(canonicalJSON).joined(separator: ",") + "]"
        case .object(let object):
            "{" + object.keys.sorted().map { quoted($0) + ":" + canonicalJSON(object[$0]!) }.joined(separator: ",") + "}"
        }
    }

    static func quoted(_ string: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = (try? encoder.encode(string)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// A single-line rendering that cannot hide part of a command. Line and
    /// paragraph separators become a visible return marker. Other control,
    /// format, invisible, and non-ASCII space characters (bidirectional
    /// overrides, zero-width characters, Hangul fillers, variation selectors)
    /// are shown as code points, since they can make text display differently
    /// from how it executes or make two commands look the same. Long runs of
    /// spaces, which could push a segment into the truncated middle, are counted.
    public static func displayLine(_ command: String) -> String {
        var result = ""
        var spaces = 0
        func flushSpaces() {
            result += spaces >= 3 ? " ␣×\(spaces) " : String(repeating: " ", count: spaces)
            spaces = 0
        }
        for scalar in command.unicodeScalars {
            if scalar == " " { spaces += 1; continue }
            flushSpaces()
            let properties = scalar.properties
            switch properties.generalCategory {
            case .lineSeparator, .paragraphSeparator:
                result += " ⏎ "
            case .control where scalar == "\n" || scalar == "\r" || scalar.value == 0x85:
                result += " ⏎ "
            case .control where scalar == "\t":
                result += " ⇥ "
            case .control, .format, .spaceSeparator:
                result += String(format: "<U+%04X>", scalar.value)
            default:
                if properties.isDefaultIgnorableCodePoint || scalar.value == 0x2800 {
                    result += String(format: "<U+%04X>", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        flushSpaces()
        return result
    }
}
