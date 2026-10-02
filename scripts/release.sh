#!/usr/bin/env bash
# Builds, signs, notarizes, and uploads a GitHub release as a draft.
#
#   SIGN_IDENTITY="Developer ID Application: ..." NOTARY_PROFILE=grantch-notary \
#       scripts/release.sh 0.1.0
#
# The release is created as a draft at the current pushed commit; GitHub
# creates the v<version> tag when the draft is published from the web UI.
set -euo pipefail

version="${1:-}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "usage: $0 <version>   (for example 0.1.0)" >&2
    exit 64
fi
tag="v$version"
: "${SIGN_IDENTITY:?set SIGN_IDENTITY to a Developer ID Application identity}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE to a notarytool keychain profile}"

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

echo "==> Preflight"
gh auth status >/dev/null 2>&1 || { echo "gh is not signed in; run gh auth login" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "working tree is not clean" >&2; exit 1; }
[[ "$(git branch --show-current)" == "main" ]] || { echo "release from main" >&2; exit 1; }
git fetch --quiet origin main --tags
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "HEAD is not origin/main; push or pull first" >&2; exit 1; }
# Drafts have no tag yet, so look them up by tag name in the release list.
release_tags="$(gh release list --limit 100 --json tagName --jq '.[].tagName')"
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null || grep -qx "$tag" <<<"$release_tags"; then
    echo "$tag already exists (delete a leftover draft with: gh release delete $tag --yes)" >&2
    exit 1
fi
grep -Eq "^## \[$version\] - [0-9]{4}-[0-9]{2}-[0-9]{2}\$" CHANGELOG.md \
    || { echo "CHANGELOG.md needs a dated heading: ## [$version] - YYYY-MM-DD" >&2; exit 1; }

echo "==> Tests"
swift test
swift build -c release
python3 Tests/Integration/config_test.py

scripts/package.sh "$version"

zip="dist/Grantch-$version-macos-universal.zip"
notes="dist/release-notes.md"
{
    awk -v version="$version" '
        $0 ~ "^## \\[" version "\\]" { printing = 1; next }
        printing && /^## / { exit }
        printing { print }
    ' CHANGELOG.md
    cat <<NOTES

## Install

1. Download \`$(basename "$zip")\`, unzip it, and move \`Grantch.app\` to \`/Applications\`.
2. Open Grantch. It runs from the notch and has no Dock icon.
3. Install the CLI hooks:

   \`\`\`sh
   /Applications/Grantch.app/Contents/MacOS/grantch-config install
   \`\`\`

4. Restart Claude Code, Codex CLI, and Antigravity CLI sessions.
5. Add Grantch to System Settings → General → Login Items so it runs after a restart.

Updating: quit Grantch (right-click the notch → \`Grantch を終了\`), replace the app, open it, and run the install command again.

Requires macOS 15 or later. Signed with the Developer ID of WANTO, K.K. (Team ID 588KRU9YN6) and notarized by Apple. Read [SECURITY.md](https://github.com/nishiyuki0501-wanto/grantch/blob/main/SECURITY.md) for what Grantch does and does not protect against.

SHA-256: \`$(cut -d ' ' -f 1 "$zip.sha256")\`
NOTES
} > "$notes"

echo "==> Creating draft release $tag"
gh release create "$tag" "$zip" "$zip.sha256" \
    --draft \
    --target "$(git rev-parse HEAD)" \
    --title "Grantch $version" \
    --notes-file "$notes"
echo "Draft created. Review and publish it on GitHub."
