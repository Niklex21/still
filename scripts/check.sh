#!/bin/bash
# Runs isolated tests. Does not launch the app UI or access your capture library.
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
mkdir -p .build/qa-snapshots
export STILL_QA_OUTPUT="$PWD/.build/qa-snapshots"
swift test --disable-sandbox --cache-path .build/cache
bin_dir=$(swift build --disable-sandbox --cache-path .build/cache --show-bin-path)
if [[ $# -gt 0 ]]; then
  "$bin_dir/Still" --self-test "$@"
else
  "$bin_dir/Still" --self-test
fi
"$bin_dir/Still" --visual-search-self-test
(cd Raycast && npm ci && npm run typecheck && npm test && npm audit --audit-level=moderate && ./node_modules/.bin/ray build --environment dist --output "$PWD/.raycast-qa" --non-interactive)
