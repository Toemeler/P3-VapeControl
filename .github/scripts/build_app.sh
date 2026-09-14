#!/usr/bin/env bash
# Build one configuration of the app with code signing disabled.
#
# usage: build_app.sh <configuration> <sdk> <bundle id> <display name>
#
# Signing is forced off because the project pins CODE_SIGN_STYLE=Automatic with
# a DEVELOPMENT_TEAM that cannot resolve on a runner without an Apple ID.
# -target rather than -scheme: the project ships no shared .xcscheme. SYMROOT
# rather than -derivedDataPath: the latter is rejected without -scheme.
#
# The Live Activity extension is a target dependency, so building the app
# target builds and embeds it too. The bundle id goes in as APP_BUNDLE_ID
# rather than PRODUCT_BUNDLE_IDENTIFIER because a command-line build setting
# applies to *every* target being built: overriding PRODUCT_BUNDLE_IDENTIFIER
# directly would give the extension the app's own id instead of its
# "<app id>.LiveActivity" suffix, which iOS rejects.
set -euo pipefail

CONFIGURATION=$1
SDK=$2
BUNDLE_ID=$3
DISPLAY_NAME=$4

PLIST=PaxController/Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $DISPLAY_NAME" "$PLIST"

xcodebuild \
  -project PaxController.xcodeproj \
  -target PaxController \
  -configuration "$CONFIGURATION" \
  -sdk "$SDK" \
  SYMROOT="$PWD/build" \
  APP_BUNDLE_ID="$BUNDLE_ID" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" \
  ONLY_ACTIVE_ARCH=NO \
  build
