#!/bin/bash
# The gate for core-kit. Run it before every push (the pre-push hook does).
#
#   scripts/verify.sh
#
# 1. the registry fixture matches core-web's (skipped when no core-web sits
#    next to this checkout; CORE_WEB_DIR points at another one)
# 2. swift build: every product, for macOS
# 3. swift test: every test target
# 4. a generic iOS build of CoreCRMUI, DocsUI and KeepUI, no simulator
#    needed: iOS-only code is invisible to the macOS build above
#
# Runs on this Mac, not in Actions: the org's macOS minutes are spent.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

step() { printf '\n==> %s\n' "$*"; }

core_web="${CORE_WEB_DIR:-$root/../core-web}"
if [ -f "$core_web/fixtures/crm/registry-v1.json" ]; then
  step "registry fixture matches core-web"
  scripts/sync-registry.sh --check
else
  step "registry fixture: no core-web checkout next to this one, not checked"
fi

step "swift build"
swift build

step "swift test"
swift test

for scheme in CoreCRMUI DocsUI KeepUI; do
  step "iOS build of $scheme (generic/platform=iOS)"
  xcodebuild build \
    -scheme "$scheme" \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$root/.build/xcode-ios" \
    CODE_SIGNING_ALLOWED=NO \
    -quiet
done

printf '\nverify: green\n'
