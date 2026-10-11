#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v swift >/dev/null 2>&1; then
  export PATH="/workspace/toolchains/swift-6.1.3-RELEASE-ubuntu24.04/usr/bin:$PATH"
fi
if [[ "$(uname -s)" == Linux ]]; then
  task_cache="${NFLPULSE_CACHE_ROOT:-/tmp/nflpulse-swift-cache}"
  mkdir -p "$task_cache"/{cache,modules,configuration,security}
  export XDG_CACHE_HOME="$task_cache/cache"
  export CLANG_MODULE_CACHE_PATH="$task_cache/modules"
  export SWIFTPM_MODULECACHE_OVERRIDE="$task_cache/modules"
  exec swift test --package-path "$repo_root" --cache-path "$task_cache/cache" \
    --config-path "$task_cache/configuration" --security-path "$task_cache/security" \
    --scratch-path "$task_cache/build" --jobs 4 "$@"
else
  exec swift test --package-path "$repo_root" "$@"
fi
