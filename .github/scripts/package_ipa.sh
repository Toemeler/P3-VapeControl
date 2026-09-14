#!/usr/bin/env bash
# Wrap a built .app into a sideloadable IPA.
#
# usage: package_ipa.sh <app path> <output ipa>
set -euo pipefail

APP=$1
OUTPUT=$2

ls -la "$APP"
file "$APP/$(basename "${APP%.app}")" || true

# Ad-hoc signature: SideStore/AltStore/Sideloadly re-sign with the user's Apple
# ID anyway, but an entirely unsigned Mach-O upsets some of those tools.
codesign --force --deep --sign - "$APP" || true

WORK=$(mktemp -d)
mkdir -p "$WORK/Payload"
cp -R "$APP" "$WORK/Payload/"
# Drop dangling symlinks, then zip while DEREFERENCING the rest (no -y) so the
# IPA contains zero symlink entries - Windows signing tools otherwise fail with
# "os error 1314 / A required privilege is not held".
find "$WORK/Payload" -type l ! -exec test -e {} \; -delete || true
echo "Symlinks left in Payload: $(find "$WORK/Payload" -type l | wc -l | tr -d ' ')"
(cd "$WORK" && zip -qr payload.ipa Payload)
mv "$WORK/payload.ipa" "$OUTPUT"
rm -rf "$WORK"
ls -lh "$OUTPUT"
