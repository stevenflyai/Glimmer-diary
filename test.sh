#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"
build_dir="${SHIGUANG_BUILD_DIR:-$project_dir/.build}"
mkdir -p "$build_dir"
runtime_dir="$(python3 "$project_dir/tools/prepare-toolchain.py" "$build_dir")"
if [[ -n "$runtime_dir" ]]; then
  export SWIFTPM_CUSTOM_LIBS_DIR="$runtime_dir"
  export SWIFTPM_MODULECACHE_OVERRIDE="$build_dir/manifest-cache"
fi
export SHIGUANG_TEST_ROOT="${SHIGUANG_TEST_ROOT:-$build_dir/test-data}"
swift run --package-path "$project_dir" --scratch-path "$build_dir" -c "${SHIGUANG_CONFIGURATION:-debug}" VaultChecks
