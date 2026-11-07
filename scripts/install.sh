#!/bin/bash
# Review this script and scripts/build.sh before running. No downloads or privilege escalation.
set -euo pipefail
cd "$(dirname "$0")/.."
destination="${STILL_INSTALL_DIR:-/Applications}"
app="$destination/Still.app"
if pgrep -f "^${app//./\.}/Contents/MacOS/Still([[:space:]]|$)" >/dev/null; then
  echo 'Quit Still from its menu-bar menu before replacing it. Closing its windows keeps it running.' >&2
  exit 1
fi
./scripts/build.sh
mkdir -p "$destination"
if [[ ! -w "$destination" ]]; then
  echo 'Destination is not writable. Use STILL_INSTALL_DIR="$HOME/Applications" ./scripts/install.sh instead.' >&2
  exit 1
fi
# Move the previous app aside only after a verified replacement is available.
staging=$(mktemp -d "$destination/.Still-install.XXXXXX")
trap 'rm -rf "$staging"' EXIT
ditto dist/Still.app "$staging/Still.app"
codesign --verify --deep --strict "$staging/Still.app"
if [[ -e "$app" ]]; then mv "$app" "$staging/Previous.app"; fi
if ! mv "$staging/Still.app" "$app"; then
  if [[ -e "$staging/Previous.app" ]]; then mv "$staging/Previous.app" "$app"; fi
  exit 1
fi
echo "Installed $app. Open it in Finder when ready."
