#!/usr/bin/env bash
# check-sidebar-driver.sh — keep scripts/verify-sidebar-interaction.{sh,swift}
# from rotting between real runs. A real run moves the pointer and needs an
# unlocked screen; this needs no display, so CI and the client suite can run it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TOOLS="$(mktemp -d "${TMPDIR:-/tmp}/usic.XXXXXX")"
trap 'rm -rf "$TOOLS"' EXIT

bash -n "$ROOT/scripts/verify-sidebar-interaction.sh"
swiftc -o "$TOOLS/driver" "$ROOT/scripts/verify-sidebar-interaction.swift"

"$TOOLS/driver" check --only toggle,scrolled-group-drop \
  || { echo "the driver rejected scenarios it should know" >&2; exit 1; }
for bad in toggel "toggle,nope" ","; do
  if "$TOOLS/driver" check --only "$bad" > /dev/null; then
    echo "the driver accepted --only '$bad'" >&2
    exit 1
  fi
done
