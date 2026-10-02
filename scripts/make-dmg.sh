#!/usr/bin/env bash
# Wraps a built app in a drag-to-install disk image with a link to
# /Applications, then signs, notarizes, and staples the image.
#
#   scripts/make-dmg.sh dist/NyankoStamina.app 0.2.0 dist/NyankoStamina-0.2.0-macos-universal.dmg
#
# SIGN_IDENTITY and NOTARY_PROFILE work as in package.sh. For a release, pass
# an app that is already notarized and stapled so it also opens offline.
set -euo pipefail

app="${1:-}"
version="${2:-}"
dmg="${3:-}"
if [[ ! -d "$app" || -z "$version" || -z "$dmg" ]]; then
    echo "usage: $0 <app> <version> <output.dmg>" >&2
    exit 64
fi
identity="${SIGN_IDENTITY:--}"
notary_profile="${NOTARY_PROFILE:-}"
if [[ -n "$notary_profile" && "$identity" == "-" ]]; then
    echo "NOTARY_PROFILE requires a Developer ID SIGN_IDENTITY" >&2
    exit 64
fi

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/$(basename "$app")"
ln -s /Applications "$staging/Applications"

echo "==> Creating $dmg"
rm -f "$dmg"
hdiutil create -volname "にゃんこのスタミナ $version" -srcfolder "$staging" -fs HFS+ -format UDZO -quiet "$dmg"

if [[ "$identity" != "-" ]]; then
    codesign --force --timestamp --sign "$identity" "$dmg"
    codesign --verify --verbose=2 "$dmg"
fi
if [[ -n "$notary_profile" ]]; then
    echo "==> Notarizing the disk image"
    NOTARY_PROFILE="$notary_profile" "$(dirname "$0")/notarize.sh" "$dmg"
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
fi

(cd "$(dirname "$dmg")" && shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256")
cat "$dmg.sha256"
