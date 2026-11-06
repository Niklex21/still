#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build -c release -debug-info-format none --disable-sandbox --cache-path "$PWD/.build/cache"
APP="$PWD/dist/Still.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Still "$APP/Contents/MacOS/Still"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/StillIcon.png "$APP/Contents/Resources/AppIcon.png"
mkdir -p .build/AppIcon.iconset
sips -z 512 512 "$APP/Contents/Resources/AppIcon.png" --out Raycast/assets/icon.png >/dev/null
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$APP/Contents/Resources/AppIcon.png" --out ".build/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$APP/Contents/Resources/AppIcon.png" --out ".build/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns .build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$APP/Contents/Resources/Raycast"
rsync -a --exclude node_modules --exclude .raycast Raycast/ "$APP/Contents/Resources/Raycast/"
cp README.md "$APP/Contents/Resources/README.md"
signing_identity="${STILL_SIGNING_IDENTITY:--}"
codesign --force --sign "$signing_identity" --identifier local.alex.Still "$APP"
echo "Built $APP"
