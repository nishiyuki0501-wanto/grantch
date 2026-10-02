# Grantch

Grantch is a local-first macOS approval surface for AI coding agents. Claude Code and Codex CLI `PermissionRequest` events and Antigravity CLI `PreToolUse` events are forwarded through a user-only Unix socket and answered from a notch-aligned macOS panel.

The interface is in Japanese. Requires macOS 15 or later.

## Install

1. Download `Grantch-<version>-macos-universal.zip` from [Releases](https://github.com/nishiyuki0501-wanto/grantch/releases), unzip it, and move `Grantch.app` to `/Applications`.
2. Open Grantch. It lives in the notch and has no Dock icon.
3. Install the CLI hooks:

   ```sh
   /Applications/Grantch.app/Contents/MacOS/grantch-config install
   ```

   The installer configures only the CLIs you have run at least once (`~/.claude`, `~/.codex`, `~/.gemini`). Run it again after installing another one.

4. Restart running Claude Code, Codex CLI, and Antigravity CLI sessions. Codex asks you to review and trust the new hook on its next launch.
5. Add Grantch to **System Settings → General → Login Items** so it is running after a restart. It does not add itself. While it is not running, Claude Code and Codex use their own prompts and Antigravity requests are denied.

To update: quit Grantch (right-click the notch → `Grantch を終了`), replace `Grantch.app`, open it, run the install command again so the copied bridge matches the app, and restart the CLIs.

Read [SECURITY.md](SECURITY.md) for what Grantch does and does not protect against.

## What works

- Native SwiftUI/AppKit `NSPanel` that stays visible across Spaces and full-screen apps
- Notch-aware hover target that extends beyond the physical cutout, expands for easier clicking, and can be pinned open with one click
- Original voxel-inspired block pattern with risk-colored tiles and pixel status indicators
- Claude Code and Codex CLI `PermissionRequest` normalization
- Antigravity CLI (`agy`) command/file-change approval via its camelCase `PreToolUse` contract; allow or deny, with Grantch as the only gate when `agy` runs with `--dangerously-skip-permissions`
- Terminal-result, tool-completion, session-end, disconnect, and parent-exit reconciliation
- Live approval queue showing the source CLI, project, command, and risk for up to three pending requests. Shell tools show their command, with markers for a disabled sandbox, escalated permissions, or a different working directory; known built-in file, web, and search tools show their name and target; every other tool, including MCP tools, shows its whole input. The agent's own description is never shown in place of the input, only in the hover text, labeled as such
- Line breaks, control characters, bidirectional and invisible characters, and unusual spaces are shown as visible markers, and long runs of spaces are counted, so nothing in a command can be hidden
- Decision buttons that ignore clicks for half a second after a request appears or moves, so a stray click cannot approve it
- Allow once, deny, deny-and-stop (Claude Code), and allow for the session when Claude Code suggests a rule; the button shows the exact rule it grants, such as `Bash(git:*)`
- Unattended auto-approval for stepping away: 15 minutes, 1 hour, or 3 hours from the notch panel or its context menu, applying to every CLI Grantch gates
- Local rule-based risk labels for destructive shell, Git, database, credential, deploy, and network operations, piping or downloading into a shell, and edits to agent, hook, SSH, Git hook, or shell startup files; hover over the label for the reasons
- Five-minute expiry, after which the request goes back to the CLI, and first-decision-wins semantics
- A red `ERROR` badge when the socket cannot be opened, instead of an idle-looking notch
- Fail-safe fallback: if Grantch is unavailable or the bridge rejects input, Claude Code and Codex fall back to their native permission UI, and Antigravity requests are denied (it has no prompt left to fall back to under `--dangerously-skip-permissions`)
- Socket at `~/Library/Application Support/Grantch/run/grantch.sock`, with directory mode `0700` and socket mode `0600`

Not implemented: Cursor support, persistence, a hook installation UI, Touch ID, terminal focus, and launch at login.

## Auto-approval

Pin the notch open (or right-click it) and choose `自動承認` with a duration to answer every request with allow-once until the timer runs out. It covers all three CLIs, so it is the equivalent of running each of them without permission prompts, and it applies to destructive operations too: high and critical risk requests are approved like any other. The notch wears a red `AUTO` badge with the remaining time and count while the mode is on, and the panel offers `+15分` and `オフ`. The panel lists what was let through. The record stays after the window ends so the run can be read back, until the next window starts or you press `消去`. The total is always counted; the 30 most recent entries are kept and the latest four shown.

The window is in-memory only. Quitting or restarting Grantch always returns to the normal asking state and clears the record.

## Build from source

```sh
swift build
swift run Grantch
```

The built bridge is `.build/debug/grantch-hook`. Install it and merge the Hook configuration safely with:

```sh
swift run grantch-config install .build/debug/grantch-hook
```

The installer adds Grantch handlers to `~/.claude/settings.json`, `~/.codex/hooks.json`, and `~/.gemini/config/hooks.json`, for the CLIs whose directory exists. Claude/Codex use permission and completion/session-end handlers; Antigravity uses a named `grantch-approval` PreToolUse hook. It does not overwrite other hooks, writes through symlinked settings files, and keeps each file's permissions. Before its first change to a file in a run it saves a private (`0600`) timestamped backup beside the settings path. The file is rewritten as pretty-printed JSON with sorted keys. Restart the CLI after installation. Codex validates newly added local hooks, so review and trust Grantch when Codex asks on the next normal launch.

To remove only the matching Grantch handler:

```sh
swift run grantch-config uninstall
```

## Manual bridge check

With Grantch running:

```sh
echo '{"session_id":"demo","cwd":"/tmp/grantch-demo","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"npm test"}}' | .build/debug/grantch-hook
```

Choosing an action in the panel prints the CLI's structured Hook response. With Grantch stopped, the same command prints `{}`, confirming native-approval fallback. The Antigravity bridge is separate; with Grantch stopped it prints an explicit denial instead:

```sh
echo '{"conversationId":"demo","workspacePaths":["/tmp/grantch-demo"],"stepIdx":1,"toolCall":{"name":"run_command","args":{"CommandLine":"npm test","Cwd":"/tmp/grantch-demo"}}}' | .build/debug/grantch-hook --source antigravity
```

## Tests

```sh
swift test
```

The current Hook contracts are documented in the official [Claude Code Hooks reference](https://code.claude.com/docs/en/hooks#permissionrequest-decision-control) and [Codex configuration schema](https://github.com/openai/codex/blob/main/codex-rs/core/config.schema.json).

## Antigravity and terminal synchronization

Antigravity exposes synchronous `PreToolUse`, not a dedicated permission-request event. Grantch therefore gates `run_command`, `write_to_file`, `replace_file_content`, `multi_replace_file_content`, and `ask_permission`, including operations Antigravity might otherwise allow automatically. Other tools, such as `view_file`, `read_url_content`, `manage_task`, subagents, and MCP tools, are not gated. It does not mirror an already-open Antigravity permission dialog.

Releasing the pre-tool gate is not the same as granting permission. On `agy 1.2.5`, a `decision: allow` response lets the step past the hook, and Antigravity then evaluates its own permission rules (`permissions.allow` in `~/.gemini/antigravity-cli/settings.json`, plus per-conversation grants) and stops on `Run this command?` in the terminal. No hook response field closes that gap: `permissionOverrides` replaces the resource string the CLI asks about rather than granting it, so `["command(echo)"]` only rewrites the prompt.

Start Antigravity as `agy --dangerously-skip-permissions` to let Grantch be the approval surface. Hooks still run under that flag and remain authoritative, so a Grantch denial blocks the step. Because the flag removes the terminal prompt, Grantch fails closed for Antigravity: an expired, cancelled, or undecidable request answers `decision: deny` rather than handing back. An empty `{}` response is read as a denial by Antigravity too, so it is never used there.

The shared `~/.gemini/config/hooks.json` customization location is also loaded by other Antigravity interfaces, so the deny-when-undecided rule applies there too.

Claude terminal hook decisions and correlated tool results dismiss the queue. Claude/Codex completion and session lifecycle hooks provide a second cleanup path; completion notifications never return an approval. Matching uses session, turn, and tool-call identifiers when available. A command-only match is accepted only for a single pending candidate. Hook disconnect, parent exit, and expiry also remove stale requests. If a CLI keeps its hook alive and emits no decision event, cleanup occurs when the tool result/completion is available rather than necessarily at the exact terminal keypress.

After installation, restart existing CLI sessions so they load the added hooks. The app and bridge must both be updated. Installer regression checks can run without touching your real settings:

```sh
swift build -c release
python3 Tests/Integration/config_test.py
```

`GRANTCH_CONFIG_HOME` overrides the installer's home directory for isolated tests. Antigravity's contract is described in its [official Hooks documentation](https://www.agy.dev/docs/hooks/).

## Debug log

If Grantch does not appear for a request, first check whether the CLI called the hook at all:

```sh
touch ~/Library/Application\ Support/Grantch/debug-hook-log
```

The bridge then appends each invocation to `~/Library/Application Support/Grantch/log/hook.log`. The log contains command text and file paths, so remove the flag file and the log when you are done.

## Uninstall

```sh
/Applications/Grantch.app/Contents/MacOS/grantch-config uninstall
```

This removes only Grantch's handlers and the copied bridge. Then quit Grantch (right-click the notch → `Grantch を終了`), delete `Grantch.app`, remove it from Login Items, and optionally delete `~/Library/Application Support/Grantch`. Backups the installer made sit next to each settings file as `*.grantch-backup-*`. Codex identifies trusted hooks partly by position, so hooks you added after Grantch's in `~/.codex/hooks.json` may need to be trusted again.

## Releasing

Releases are built locally, signed with a Developer ID, notarized, and uploaded as a draft GitHub release. One-time setup stores notarization credentials in the keychain:

```sh
xcrun notarytool store-credentials grantch-notary --apple-id <apple-id> --team-id <team-id>
```

For each release, add a `## [x.y.z] - YYYY-MM-DD` section to [CHANGELOG.md](CHANGELOG.md), push `main`, then run:

```sh
SIGN_IDENTITY="Developer ID Application: <name> (<team-id>)" NOTARY_PROFILE=grantch-notary scripts/release.sh x.y.z
```

The script refuses to run on a dirty or unpushed tree, runs the tests, builds a universal app, signs, notarizes, staples, and creates a draft release with the zip and its SHA-256. Publishing the draft on GitHub creates the `vx.y.z` tag. `scripts/package.sh x.y.z` alone builds an ad-hoc signed app for local testing.

## License

[MIT](LICENSE)
