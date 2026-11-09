#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"

build_args=(-c release -debug-info-format none --disable-sandbox --cache-path "$PWD/.build/cache")
if [[ -n "${STILL_ARCHS:-}" ]]; then
  read -r -a architectures <<< "$STILL_ARCHS"
  for architecture in "${architectures[@]}"; do
    case "$architecture" in arm64|x86_64) ;; *) echo "Unsupported architecture: $architecture" >&2; exit 1 ;; esac
    build_args+=(--arch "$architecture")
  done
fi
swift build "${build_args[@]}"
bin_dir=$(swift build "${build_args[@]}" --show-bin-path)

# Assemble a fresh bundle so old build output cannot leak into a release.
staging=$(mktemp -d "$PWD/.build/StillBundle.XXXXXX")
trap 'rm -rf "$staging"' EXIT
APP="$staging/Still.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$bin_dir/Still" "$APP/Contents/MacOS/Still"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -n "${STILL_USAGE_TOKEN:-}" || -n "${STILL_USAGE_REGION:-}" ]]; then
  if [[ ! "${STILL_USAGE_TOKEN:-}" =~ ^phc_[a-zA-Z0-9_]+$ || ! "${STILL_USAGE_REGION:-}" =~ ^(US|EU)$ ]]; then
    echo 'Usage counts require a public Still project token and US or EU region.' >&2
    exit 1
  fi
  plutil -insert StillUsageToken -string "$STILL_USAGE_TOKEN" "$APP/Contents/Info.plist"
  plutil -insert StillUsageRegion -string "$STILL_USAGE_REGION" "$APP/Contents/Info.plist"
fi
mkdir -p "$APP/Contents/Frameworks"
ditto "$PWD/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp .build/artifacts/sparkle/Sparkle/LICENSE "$APP/Contents/Resources/Sparkle-LICENSE"
cp Resources/StillIcon.png "$APP/Contents/Resources/AppIcon.png"
mkdir -p "$staging/AppIcon.iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$APP/Contents/Resources/AppIcon.png" --out "$staging/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$APP/Contents/Resources/AppIcon.png" --out "$staging/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$staging/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$APP/Contents/Resources/Raycast"
for item in package.json package-lock.json tsconfig.json raycast-env.d.ts src assets tests; do
  ditto "Raycast/$item" "$APP/Contents/Resources/Raycast/$item"
done
cp README.md "$APP/Contents/Resources/README.md"
cp LICENSE "$APP/Contents/Resources/LICENSE"
signing_identity="${STILL_SIGNING_IDENTITY:--}"
signing_args=(--force --sign "$signing_identity" --identifier local.alex.Still)
if [[ "$signing_identity" == "Developer ID Application:"* ]]; then
  sparkle="$APP/Contents/Frameworks/Sparkle.framework"
  for component in "$sparkle/Versions/B/XPCServices/Downloader.xpc" "$sparkle/Versions/B/XPCServices/Installer.xpc" "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle"; do
    codesign --force --sign "$signing_identity" --options runtime --timestamp --preserve-metadata=identifier,entitlements "$component"
  done
  signing_args+=(--options runtime --timestamp)
fi
codesign "${signing_args[@]}" "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p dist
rm -rf "$PWD/dist/Still.app"
ditto "$APP" "$PWD/dist/Still.app"
echo "Built $PWD/dist/Still.app ($(lipo -archs "$PWD/dist/Still.app/Contents/MacOS/Still"))"
