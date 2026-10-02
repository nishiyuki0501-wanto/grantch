#!/usr/bin/env bash
# Builds the universal app (にゃんこのスタミナ / Nyanko no Stamina) and a
# distributable disk image and zip in dist/.
#
#   scripts/package.sh 0.2.0
#
# SIGN_IDENTITY   codesign identity. Defaults to "-" (ad-hoc, local use only).
#                 Use a "Developer ID Application: ..." identity for releases.
# NOTARY_PROFILE  notarytool keychain profile. When set, the app and the disk
#                 image are notarized and stapled; requires a Developer ID
#                 SIGN_IDENTITY.
set -euo pipefail

version="${1:-}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "usage: $0 <version>   (for example 0.1.0)" >&2
    exit 64
fi
identity="${SIGN_IDENTITY:--}"
notary_profile="${NOTARY_PROFILE:-}"
if [[ -n "$notary_profile" && "$identity" == "-" ]]; then
    echo "NOTARY_PROFILE requires a Developer ID SIGN_IDENTITY" >&2
    exit 64
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
dist="$root/dist"
# The bundle's file name stays ASCII so the installer path is easy to type;
# Finder shows the localized name from Localization/*.lproj/InfoPlist.strings.
app_file="NyankoStamina"
app="$dist/$app_file.app"
artifact="$dist/$app_file-$version-macos-universal"
zip="$artifact.zip"
dmg="$artifact.dmg"
bundle_id="com.wanto.grantch"

echo "==> Building universal release binaries"
swift build -c release --arch arm64 --arch x86_64
bin="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

echo "==> Assembling $app"
rm -rf "$dist"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Grantch" "$bin/grantch-hook" "$bin/grantch-config" "$app/Contents/MacOS/"
cp Assets/Grantch.icns LICENSE "$app/Contents/Resources/"
cp -R Localization/ja.lproj Localization/en.lproj "$app/Contents/Resources/"
# Debug symbols carry absolute build paths (and so the builder's home
# directory and user name); release binaries ship without them.
strip -S -x "$app/Contents/MacOS/Grantch" "$app/Contents/MacOS/grantch-hook" "$app/Contents/MacOS/grantch-config" 2>/dev/null
for leaked in "$HOME" "$root"; do
    if LC_ALL=C grep -r -a -l -F "$leaked" "$app"; then
        echo "a local path ($leaked) is embedded in the files above" >&2
        exit 1
    fi
done
build_number="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>ja</string>
    <key>CFBundleDisplayName</key><string>$app_file</string>
    <key>CFBundleExecutable</key><string>Grantch</string>
    <key>CFBundleIconFile</key><string>Grantch</string>
    <key>CFBundleIdentifier</key><string>$bundle_id</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleLocalizations</key><array><string>ja</string><string>en</string></array>
    <key>CFBundleName</key><string>$app_file</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$build_number</string>
    <key>LSHasLocalizedDisplayName</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Yuki Nishisaka. MIT License.</string>
</dict>
</plist>
PLIST
plutil -lint "$app/Contents/Info.plist" >/dev/null

echo "==> Signing with identity: $identity"
sign_flags=(--force --options runtime)
if [[ "$identity" == "-" ]]; then
    sign_flags+=(--timestamp=none)
else
    sign_flags+=(--timestamp)
fi
# Nested executables first, then the bundle that seals them.
codesign "${sign_flags[@]}" --sign "$identity" --identifier "$bundle_id.hook" "$app/Contents/MacOS/grantch-hook"
codesign "${sign_flags[@]}" --sign "$identity" --identifier "$bundle_id.config" "$app/Contents/MacOS/grantch-config"
codesign "${sign_flags[@]}" --sign "$identity" "$app"
codesign --verify --strict --deep --verbose=2 "$app"

# Extended attributes (provenance, quarantine) would otherwise ship as
# __MACOSX/._* entries; the signature does not depend on them.
archive() { ditto -c -k --norsrc --noextattr --keepParent "$1" "$2"; }

if [[ -n "$notary_profile" ]]; then
    echo "==> Notarizing the app (this can take a few minutes)"
    archive "$app" "$dist/notarize.zip"
    NOTARY_PROFILE="$notary_profile" scripts/notarize.sh "$dist/notarize.zip"
    rm "$dist/notarize.zip"
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose=2 "$app"
fi

echo "==> Creating $zip"
archive "$app" "$zip"
(cd "$dist" && shasum -a 256 "$(basename "$zip")" > "$(basename "$zip").sha256")
cat "$zip.sha256"

SIGN_IDENTITY="$identity" NOTARY_PROFILE="$notary_profile" scripts/make-dmg.sh "$app" "$version" "$dmg"
