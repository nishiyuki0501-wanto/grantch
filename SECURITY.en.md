# Security Policy

[日本語](SECURITY.md) | English

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub: open the repository's **Security** tab and choose **Report a vulnerability**. Do not open a public issue for anything that could let an agent run an operation the user did not approve.

Include the app version, macOS version, the CLI involved (Claude Code, Codex CLI, or Antigravity CLI) and its version, and steps to reproduce. Reports are read and answered as soon as possible. Reports in Japanese or English are welcome.

Only the latest release receives fixes.

## Security model

Grantch (project name `grantch`) is an approval surface, not a sandbox. Knowing where its protection ends matters as much as what it does.

**Trust boundary: your macOS user account.** The bridge talks to the app over a Unix socket at `~/Library/Application Support/Grantch/run/grantch.sock`. The directory is `0700`, the socket is `0600`, and the app rejects peers whose user ID differs from its own. Any process already running as you can still connect, submit requests, or dismiss pending ones. The app does not defend against software that already runs under your account.

**It answers only what the CLI asks.** Claude Code and Codex CLI send a request when they would otherwise show their own permission prompt. Anything those CLIs already allow (allowlists, `--dangerously-skip-permissions`, bypass or full-auto modes) never reaches the app. An agent that is allowed to edit `~/.claude/settings.json`, `~/.codex/hooks.json`, or `~/.gemini/config/hooks.json` can also remove the hook; such edits are labeled critical.

**Antigravity runs with the app as its only gate.** The recommended `agy --dangerously-skip-permissions` removes Antigravity's own prompt. The app then gates only `run_command`, file writes, `ask_permission`, and MCP tools. Other tools, including `view_file`, `read_url_content`, `manage_task`, and subagents, run without asking. It fails closed for the gated tools while its hook is loaded (an expired, cancelled, or undecidable request is denied), but if the hook is not loaded, nothing asks before any tool runs.

**What you see is the input, not the agent's account of it.** Shell tools show their command, marked when the sandbox is disabled, permissions are escalated, or a working directory is set. Known built-in file, web, and search tools show their name and target. Every other tool, including MCP tools, shows its whole input as JSON. An agent-written `description` appears only in the hover text, labeled as the agent's description. Line breaks, control characters, bidirectional and invisible characters, and non-ASCII spaces are shown as visible markers, and long runs of spaces are counted, because all of these can make text display differently from how it executes. Tool input nested more than 64 levels deep is not decoded; such a request falls back as described below. Long commands are truncated in the middle; hover over the command to read all of it before approving. Codex reports the host of a network-access approval only in its description, so check the hover text for those.

**Risk labels are keyword heuristics.** They choose between one-click and press-and-hold approval and help you prioritize. They do not analyze what a command does, and a command labeled low risk can still be destructive. Hover over the label for the reasons it was given.

**Session approval can be broader than the request.** For Claude Code, the session button applies the rule Claude Code suggested, and the button shows that rule. A rule such as `Bash(git:*)` covers every matching call for the rest of the session, including riskier ones, and those calls no longer reach the app. It always limits the rule to the session, whatever destination Claude Code suggested.

**Auto-approval approves everything.** While it is on, every request from every CLI, critical ones included, is allowed without asking. It lasts at most until its timer ends or the app quits. Its record of what it let through stays visible until the next window starts or you clear it.

**Fail-safe defaults.** If the app is not running or the bridge cannot complete a request, Claude Code and Codex CLI fall back to their own permission prompt, and Antigravity requests are denied. Unanswered requests go back to the CLI the same way after five minutes. Completion and session-end notifications only dismiss a pending request; they never approve one. If the app cannot open its socket, the notch shows a red `ERROR` badge rather than looking idle. It does not start at login unless you add it to Login Items.

**Misclick protection.** Decision buttons ignore clicks for half a second after a request appears or moves up in the queue, so a click aimed at something else cannot approve it. High and critical requests need a 1.2-second press-and-hold.

**Local only.** The app makes no network connections and collects no telemetry. Requests are held in memory only.

**Debug log.** Creating `~/Library/Application Support/Grantch/debug-hook-log` makes the bridge append every hook invocation, including command text and file paths, to `~/Library/Application Support/Grantch/log/hook.log` (mode `0600`, reset at 1 MB). Delete the flag file to stop logging, and delete the log when you are done.

**Installer.** `grantch-config` edits only the hook sections it owns and backs up each existing file once per run, beside the settings path, readable only by you. Settings files can contain tokens, so do not commit those backups.

## Release integrity

Release builds are signed with the Developer ID of WANTO, K.K. (Team ID `588KRU9YN6`) and notarized by Apple, both the app and the disk image. Release binaries ship without debug symbols. Each release lists the SHA-256 of its files. To check a download:

```sh
shasum -a 256 -c Grantch-*-macos-universal.dmg.sha256
spctl --assess --type open --context context:primary-signature --verbose=2 Grantch-*-macos-universal.dmg
codesign -dv --verbose=2 /Applications/Grantch.app 2>&1 | grep -E 'Authority=Developer ID|TeamIdentifier'
spctl --assess --type execute --verbose=2 /Applications/Grantch.app
```

`TeamIdentifier` must read `588KRU9YN6`, and `spctl` must report `source=Notarized Developer ID`.
