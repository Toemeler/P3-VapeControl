#!/usr/bin/env bash
# Build one configuration of the app with code signing disabled.
#
# usage: build_app.sh <configuration> <sdk> <bundle id> <display name>
#
# Signing is forced off because the project pins CODE_SIGN_STYLE=Automatic with
# a DEVELOPMENT_TEAM that cannot resolve on a runner without an Apple ID.
#
# -scheme with a destination rather than -target with an -sdk. The app now
# embeds a watchOS app, and -sdk applies one SDK to every target in the build,
# which a watch target cannot be built with. A destination lets Xcode pick the
# right SDK per target: the phone app against iOS, the watch app against
# watchOS, in one invocation. SYMROOT keeps the output where the packaging step
# already looks for it.
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
shift 4
# Anything further is passed to xcodebuild as-is, which is how the lab build
# turns its own code on with SWIFT_ACTIVE_COMPILATION_CONDITIONS.

PLIST=PaxController/Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $DISPLAY_NAME" "$PLIST"

case "$SDK" in
  iphonesimulator) DESTINATION="generic/platform=iOS Simulator" ;;
  iphoneos)        DESTINATION="generic/platform=iOS" ;;
  *) echo "unknown sdk: $SDK" >&2; exit 2 ;;
esac

xcodebuild \
  -project PaxController.xcodeproj \
  -scheme PaxController \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  SYMROOT="$PWD/build" \
  APP_BUNDLE_ID="$BUNDLE_ID" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" \
  ONLY_ACTIVE_ARCH=NO \
  "$@" \
  build
