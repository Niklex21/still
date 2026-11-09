#!/bin/bash
# Review this script and scripts/build.sh before running. SwiftPM resolves the pinned updater dependency.
set -euo pipefail
cd "$(dirname "$0")/.."
destination="${STILL_INSTALL_DIR:-/Applications}"
app="$destination/Still.app"
if pgrep -f "^${app//./\.}/Contents/MacOS/Still([[:space:]]|$)" >/dev/null; then
  echo 'Quit Still from its menu-bar menu before replacing it. Closing its windows keeps it running.' >&2
  exit 1
fi
mkdir -p "$destination"
if [[ ! -w "$destination" ]]; then
  echo 'Destination is not writable. Use STILL_INSTALL_DIR="$HOME/Applications" ./scripts/install.sh instead.' >&2
  exit 1
fi
# Move the previous app aside only after a verified replacement is available.
staging=$(mktemp -d "$destination/.Still-install.XXXXXX")
trap 'rm -rf "$staging"' EXIT
# macOS matches Screen Recording approval against the previous app's designated
# requirement. Preserve a local development identity across source rebuilds.
previous_requirement=
if [[ -z "${STILL_SIGNING_IDENTITY:-}" && -d "$app" ]]; then
  signature=$(codesign -dv --verbose=4 "$app" 2>&1 || true)
  signer=$(awk '/^Authority=/ {sub(/^Authority=/,""); print; exit}' <<< "$signature")
  if [[ "$signer" == "Apple Development: "* ]]; then
    previous_requirement=$(codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => //p')
    if [[ -z "$previous_requirement" ]]; then
      echo 'Could not read the installed app’s signing requirement.' >&2
      exit 1
    fi
    export STILL_SIGNING_IDENTITY="$signer"
  fi
fi
./scripts/build.sh
ditto dist/Still.app "$staging/Still.app"
codesign --verify --deep --strict "$staging/Still.app"
if [[ -n "$previous_requirement" ]]; then
  codesign --verify -R="$previous_requirement" "$staging/Still.app"
fi
if [[ -e "$app" ]]; then mv "$app" "$staging/Previous.app"; fi
if ! mv "$staging/Still.app" "$app"; then
  if [[ -e "$staging/Previous.app" ]]; then mv "$staging/Previous.app" "$app"; fi
  exit 1
fi
echo "Installed $app. Open it in Finder when ready."
