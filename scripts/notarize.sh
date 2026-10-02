#!/usr/bin/env bash
# Submits a zip or disk image for notarization, waits for the result, and
# prints Apple's log when it is not accepted.
#
#   NOTARY_PROFILE=grantch-notary scripts/notarize.sh dist/Grantch.dmg
set -euo pipefail

file="${1:?usage: $0 <zip-or-dmg>}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE to a notarytool keychain profile}"

result="$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)" || true
submission_id="$(plutil -extract id raw -o - - <<<"$result" 2>/dev/null)" \
    || { echo "Notarization submission failed: $result" >&2; exit 1; }
status="$(plutil -extract status raw -o - - <<<"$result" 2>/dev/null)" || status="unknown"
if [[ "$status" != "Accepted" ]]; then
    echo "Notarization $status. Apple's log:" >&2
    xcrun notarytool log "$submission_id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    exit 1
fi
echo "Notarization accepted: $(basename "$file")"
