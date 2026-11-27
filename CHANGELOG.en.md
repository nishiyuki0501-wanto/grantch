# Changelog

[日本語](CHANGELOG.md) | English

All notable changes are recorded here. Versions follow [Semantic Versioning](https://semver.org/).

## [0.2.3] - 2026-11-27

### Added and improved

- The panel now follows the display. On a Mac with a notch, the shell is cut for that model's notch. On a Mac or external display without one, a small tab sits at the top edge and the panel has no cutout.
- The `AUTO` and `ERROR` badges now sit flush under the notch.

### Fixed

- Even when idle, the area under the notch (about 34 points below the menu bar) took clicks, so browser tabs right under the menu bar could not be closed or selected. The notch now responds to the pointer only within the menu bar's height, and the `AUTO` and `ERROR` badges let clicks through to the app below.

## [0.2.2] - 2026-11-23

0.2.1 was never published, so its changes ship in this release.

### Added and improved

- Added 8-hour, until-turned-off, and custom durations. Direct minute input appears only for Custom.
- Improved extension controls, notch click targets, input contrast, and panel spacing.

### Fixed

- A bridge copied out of an app downloaded from GitHub kept the download quarantine flag. Claude Code and Codex then could not launch it, so no approval, including auto-approval, ever arrived. The installer removes the flag when it copies the bridge, and the app removes it again on launch, so opening this version repairs an existing install.
- The whole open notch panel was one click target, so the 15-minute, 1-hour, and 3-hour buttons only unpinned the panel and auto-approval never started. Those buttons and the right-click menu now receive the click.
- Antigravity MCP tools (`call_mcp_tool`) were outside the hook, so Antigravity's own prompt appeared even during auto-approval. MCP tools are now gated and shown as `mcp server/tool arguments`. Run `grantch-config install` again to apply it.
- In Claude Code, a request without a tool-call ID (such as a tool run from inside a script) could match an earlier, finished call with the same command. Grantch read that as a terminal answer and fell back to the native prompt, even during auto-approval. Calls that already have a result are no longer matched.

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
