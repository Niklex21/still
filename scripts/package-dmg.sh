#!/bin/bash
# Build a universal app and package it as a drag-to-Applications disk image.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -n "${STILL_NOTARY_PROFILE:-}" && "${STILL_SIGNING_IDENTITY:-}" != "Developer ID Application:"* ]]; then
  echo 'Notarization requires STILL_SIGNING_IDENTITY to name a Developer ID Application certificate.' >&2
  exit 1
fi
# Official disk images offer opt-in counts; plain source installs omit the integration.
if [[ -z "${STILL_USAGE_TOKEN+x}" && -z "${STILL_USAGE_REGION+x}" ]]; then
  source Resources/release-usage.env
  export STILL_USAGE_TOKEN STILL_USAGE_REGION
fi
export STILL_ARCHS="${STILL_ARCHS:-arm64 x86_64}"
./scripts/build.sh
app="$PWD/dist/Still.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
label="${STILL_RELEASE_LABEL:-$version}"
if [[ ! "$label" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo 'STILL_RELEASE_LABEL must contain only letters, digits, dots, underscores, or hyphens.' >&2
  exit 1
fi
architectures=$(lipo -archs "$app/Contents/MacOS/Still")
if [[ "$architectures" == *arm64* && "$architectures" == *x86_64* ]]; then
  platform=universal
elif [[ "$architectures" == *arm64* ]]; then
  platform=arm64
else
  platform=x86_64
fi
name="Still-$label-$platform"
staging=$(mktemp -d "$PWD/.build/StillDMG.XXXXXX")
trap 'rm -rf "$staging"' EXIT
mkdir -p "$staging/volume"
ditto "$app" "$staging/volume/Still.app"
ln -s /Applications "$staging/volume/Applications"
# The ticket is stapled to the app before the final DMG is assembled.
if [[ -n "${STILL_NOTARY_PROFILE:-}" ]]; then
  ditto -c -k --sequesterRsrc --keepParent "$staging/volume/Still.app" "$staging/Still-notarize.zip"
  xcrun notarytool submit "$staging/Still-notarize.zip" --keychain-profile "$STILL_NOTARY_PROFILE" --wait
  xcrun stapler staple "$staging/volume/Still.app"
  xcrun stapler validate "$staging/volume/Still.app"
fi
hdiutil create -volname Still -srcfolder "$staging/volume" -ov -format UDZO -imagekey zlib-level=9 "$PWD/dist/$name.dmg"
if [[ -n "${STILL_NOTARY_PROFILE:-}" ]]; then
  codesign --sign "$STILL_SIGNING_IDENTITY" --timestamp "$PWD/dist/$name.dmg"
  xcrun notarytool submit "$PWD/dist/$name.dmg" --keychain-profile "$STILL_NOTARY_PROFILE" --wait
  xcrun stapler staple "$PWD/dist/$name.dmg"
  xcrun stapler validate "$PWD/dist/$name.dmg"
else
  echo 'Preview: this DMG is not notarized. See docs/releases.md before distributing.'
fi
hdiutil verify "$PWD/dist/$name.dmg"
(cd dist && shasum -a 256 "$name.dmg" > "$name.dmg.sha256")
echo "Packaged $PWD/dist/$name.dmg"
