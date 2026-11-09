#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
tag=${1:-}
if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-preview\.[0-9]+)?$ ]]; then
  echo "Usage: $0 vX.Y.Z[-preview.N]" >&2
  exit 1
fi
repo=Niklex21/still
name="Still-${tag#v}-universal.dmg"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
[[ "$(gh release view "$tag" -R "$repo" --json isDraft --jq .isDraft)" == false ]]
gh release download "$tag" -R "$repo" -p "$name" -p "$name.sha256" -D "$stage"
(cd "$stage" && shasum -a 256 -c "$name.sha256")
tools=.build/artifacts/sparkle/Sparkle/bin
account=org.Niklex21.Still.updates
base="https://github.com/$repo/releases"
cp docs/appcast.xml "$stage/appcast.xml"
"$tools/generate_appcast" --account "$account" --maximum-deltas 0 \
  --download-url-prefix "$base/download/$tag/" --full-release-notes-url "$base/tag/$tag" "$stage"
# Check the exact published asset against the public key embedded in Still.
xcrun swift scripts/verify-update.swift "$stage/appcast.xml" "$base/download/$tag/$name" "$stage/$name" Resources/Info.plist
cp "$stage/appcast.xml" docs/appcast.xml
