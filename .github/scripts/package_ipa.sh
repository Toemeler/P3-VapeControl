#!/usr/bin/env bash
# Wrap a built .app into a sideloadable IPA.
#
# usage: package_ipa.sh <app path> <output ipa>
set -euo pipefail

APP=$1
OUTPUT=$2

ls -la "$APP"
# The folder name inside Payload/ is what sideloaders show as the app, so it
# has to stay PaxController.app - not the build directory it came from.
case "$(basename "$APP")" in
  *.app) ;;
  *) echo "::error::$APP is not a .app bundle"; exit 1 ;;
esac
file "$APP/$(basename "$APP" .app)" || true

# Ad-hoc signature: SideStore/AltStore/Sideloadly re-sign with the user's Apple
# ID anyway, but an entirely unsigned Mach-O upsets some of those tools.
codesign --force --deep --sign - "$APP" || true

WORK=$(mktemp -d)
mkdir -p "$WORK/Payload"
cp -R "$APP" "$WORK/Payload/"

# A Watch app cannot survive sideloading, so it does not travel in this IPA.
#
# SideStore and AltStore re-sign the iOS app under a per-account bundle id --
# "de.marcomeissner.PaxController.9YHLT3UZJ6" rather than the id it was built
# with -- because free provisioning has to keep one person's copy distinct from
# another's. Nothing rewrites WKCompanionAppBundleIdentifier inside the embedded
# Watch app, which still names the original, so iOS rejects the whole install:
#
#   InvalidCompanionAppBundleIdentifier: The Watch app contained within this app
#   has an incorrect value ... for the WKCompanionAppBundleIdentifier key
#
# That fails the phone app too, which is what this IPA exists to deliver. The
# key cannot be fixed here either: the suffix is assigned at install time by the
# sideloader, from the Apple ID doing the signing, and is not knowable at build.
#
# An Xcode build against a real team embeds the Watch app as usual; this only
# strips it from the sideloadable artifact.
WATCH="$WORK/Payload/$(basename "$APP")/Watch"
if [ -d "$WATCH" ]; then
  echo "Stripping embedded Watch app so the IPA can be sideloaded: $(ls "$WATCH" | tr '\n' ' ')"
  rm -rf "$WATCH"
else
  echo "No embedded Watch app to strip."
fi

# Drop dangling symlinks, then zip while DEREFERENCING the rest (no -y) so the
# IPA contains zero symlink entries - Windows signing tools otherwise fail with
# "os error 1314 / A required privilege is not held".
find "$WORK/Payload" -type l ! -exec test -e {} \; -delete || true
echo "Symlinks left in Payload: $(find "$WORK/Payload" -type l | wc -l | tr -d ' ')"
(cd "$WORK" && zip -qr payload.ipa Payload)
mv "$WORK/payload.ipa" "$OUTPUT"
rm -rf "$WORK"
ls -lh "$OUTPUT"
