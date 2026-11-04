#!/bin/bash
# Keep Tests/CoreKitTests/Fixtures/registry-v1.json equal to Core's.
#
#   scripts/sync-registry.sh           copy Core's fixture over ours
#   scripts/sync-registry.sh --check   fail when the two differ; change nothing
#
# The source is core-web/fixtures/crm/registry-v1.json, in a checkout next to
# this one (../core-web). Set CORE_WEB_DIR to use another checkout, for
# example when this repo is a worktree. The fixture is generated in core-web
# (`pnpm crm:registry:generate`); never edit our copy by hand.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
core_web="${CORE_WEB_DIR:-$root/../core-web}"
source_file="$core_web/fixtures/crm/registry-v1.json"
target_file="$root/Tests/CoreKitTests/Fixtures/registry-v1.json"

mode="sync"
case "${1:-}" in
  "") ;;
  --check) mode="check" ;;
  *) echo "usage: scripts/sync-registry.sh [--check]" >&2; exit 2 ;;
esac

if [ ! -f "$source_file" ]; then
  echo "sync-registry: no $source_file (set CORE_WEB_DIR to a core-web checkout)" >&2
  exit 2
fi

if cmp -s "$source_file" "$target_file"; then
  echo "sync-registry: registry-v1.json matches core-web"
  exit 0
fi

if [ "$mode" = "check" ]; then
  echo "sync-registry: registry-v1.json differs from $source_file" >&2
  echo "  run scripts/sync-registry.sh, fix what the new registry breaks, commit" >&2
  echo "  (if core-web is behind its origin/main, update it first: this compares files, not commits)" >&2
  exit 1
fi

cp "$source_file" "$target_file"
echo "sync-registry: copied $source_file"
echo "  next: scripts/verify.sh"
