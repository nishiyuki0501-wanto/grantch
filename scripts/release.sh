#!/usr/bin/env bash
# Builds, signs, notarizes, and uploads a GitHub release as a draft.
#
#   SIGN_IDENTITY="Developer ID Application: ..." NOTARY_PROFILE=grantch-notary \
#       scripts/release.sh 0.2.0
#
# The release is created as a draft at the current pushed commit; GitHub
# creates the v<version> tag when the draft is published from the web UI.
set -euo pipefail

version="${1:-}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "usage: $0 <version>   (for example 0.2.0)" >&2
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
for changelog in CHANGELOG.md CHANGELOG.en.md; do
    grep -Eq "^## \[$version\] - [0-9]{4}-[0-9]{2}-[0-9]{2}\$" "$changelog" \
        || { echo "$changelog needs a dated heading: ## [$version] - YYYY-MM-DD" >&2; exit 1; }
done

echo "==> Tests"
swift test
swift build -c release
python3 Tests/Integration/config_test.py
python3 Tests/Integration/localization_test.py

scripts/package.sh "$version"

artifact="dist/NyankoStamina-$version-macos-universal"
dmg="$artifact.dmg"
zip="$artifact.zip"
notes="dist/release-notes.md"
section() {
    awk -v version="$version" '
        $0 ~ "^## \\[" version "\\]" { printing = 1; next }
        printing && /^## / { exit }
        printing { print }
    ' "$1"
}
{
    section CHANGELOG.md
    cat <<NOTES

## インストール

1. \`$(basename "$dmg")\` をダウンロードして開き、「にゃんこのスタミナ」を「アプリケーション」フォルダへドラッグします。
2. 「にゃんこのスタミナ」を開きます。ノッチに常駐し、Dock には表示されません。
3. CLI のフックをインストールします。

   \`\`\`sh
   /Applications/NyankoStamina.app/Contents/MacOS/grantch-config install
   \`\`\`

4. 起動中の Claude Code・Codex CLI・Antigravity CLI を再起動します。
5. 再起動後も動くように、システム設定 →「一般」→「ログイン項目」に追加します。

更新するときは、ノッチを右クリック →「にゃんこのスタミナを終了」で終了し、アプリを置き換えて開き、もう一度 install を実行します。zip 版も同じ内容です。

macOS 15 以降が必要です。WANTO, K.K.（Team ID 588KRU9YN6）の Developer ID で署名し、Apple の公証を受けています。守れる範囲と守れない範囲は [SECURITY.md](https://github.com/nishiyuki0501-wanto/grantch/blob/main/SECURITY.md) を読んでください。

---

## English

NOTES
    section CHANGELOG.en.md
    cat <<NOTES

### Install

1. Download \`$(basename "$dmg")\`, open it, and drag Nyanko no Stamina to Applications.
2. Open Nyanko no Stamina. It runs from the notch and has no Dock icon. The interface follows your macOS language (Japanese or English).
3. Install the CLI hooks:

   \`\`\`sh
   /Applications/NyankoStamina.app/Contents/MacOS/grantch-config install
   \`\`\`

4. Restart running Claude Code, Codex CLI, and Antigravity CLI sessions.
5. Add the app to System Settings → General → Login Items so it runs after a restart.

To update: right-click the notch → Quit Nyanko no Stamina, replace the app, open it, and run the install command again. The zip contains the same app.

Requires macOS 15 or later. Signed with the Developer ID of WANTO, K.K. (Team ID 588KRU9YN6) and notarized by Apple. Read [SECURITY.en.md](https://github.com/nishiyuki0501-wanto/grantch/blob/main/SECURITY.en.md) for what it does and does not protect against.

---

SHA-256

- \`$(basename "$dmg")\`: \`$(cut -d ' ' -f 1 "$dmg.sha256")\`
- \`$(basename "$zip")\`: \`$(cut -d ' ' -f 1 "$zip.sha256")\`
NOTES
} > "$notes"

echo "==> Creating draft release $tag"
gh release create "$tag" "$dmg" "$dmg.sha256" "$zip" "$zip.sha256" \
    --draft \
    --target "$(git rev-parse HEAD)" \
    --title "にゃんこのスタミナ $version" \
    --notes-file "$notes"
echo "Draft created. Review and publish it on GitHub."
