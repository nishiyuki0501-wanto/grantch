# Changelog

[日本語](CHANGELOG.md) | English

All notable changes are recorded here. Versions follow [Semantic Versioning](https://semver.org/).

## [0.2.0] - 2026-10-02

### Changed

- Japanese is the base language throughout, with English available: the interface and risk reasons follow your macOS language, `grantch-config` prints Japanese or English (`GRANTCH_LANG` overrides it), and the documentation is in Japanese with English versions.
- The status message Claude Code and Codex show while waiting is written in the installer's language.

### Added

- A signed and notarized disk image (`.dmg`) with a link to Applications, alongside the zip.

### Fixed

- The installer no longer backs up a settings file it created in the same run.

## [0.1.0] - 2026-10-02

First public release.

### Added

- Notch-aligned approval panel for Claude Code and Codex CLI `PermissionRequest` hooks and Antigravity CLI `PreToolUse` hooks.
- Allow once, deny, deny-and-stop (Claude Code), and allow for the session with the granted rule shown (Claude Code).
- Rule-based risk labels with their reasons on hover; high and critical requests need a press-and-hold to approve.
- Timed auto-approval (15 minutes, 1 hour, 3 hours) with a record of what was let through that stays after the window ends.
- `grantch-config` installer that configures only CLIs that are present, merges hooks without touching other handlers, keeps file permissions and symlinks, and backs up each file once per run.
- `Grantch を終了` in the notch's context menu, and a red `ERROR` badge when the socket cannot be opened.
- Signed and notarized universal (Apple silicon and Intel) app bundle.

### Security

- Known built-in tools show their name and target (for example `Write /path/to/.env`); MCP and other tools show their whole input; shell commands are marked for a disabled sandbox, escalation, or a working directory. The agent's description is never shown in place of the input. Risk labels are computed from the same text.
- Line and paragraph separators, control characters, bidirectional and invisible characters, and non-ASCII spaces are shown as visible markers, and long runs of spaces are counted.
- Risk labels catch `rm` however it is written, piping or downloading into a shell, and edits to agent, hook, Git hook, SSH, and shell startup files.
- Tool input nested more than 64 levels deep is rejected instead of crashing the app.
- Session approval is offered only for Claude Code `addRules` suggestions.
- Decision buttons ignore clicks for 0.5 seconds after a request appears or moves.
- The socket server rejects peers running as another user, reused request IDs, and peers that stall mid-message, and closes sockets only after their dispatch source is cancelled.
- Unanswered requests go back to the CLI after five minutes instead of being reported as denied by the user.
- Claude Code `Stop` no longer dismisses requests from background subagents.
- The opt-in debug log and installer backups are created readable by the user only.
