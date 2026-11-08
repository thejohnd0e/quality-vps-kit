#!/bin/sh
# Generic command stub for tests. Installed under the name of the command it
# replaces. Prints the fixture "$QVK_STUB_DIR/<key>" where <key> is
# "<command> <args>" with every character outside [A-Za-z0-9._-] replaced by
# "_"; exits with the number in "<key>.exit" (default 0). Without a fixture it
# fails with 127. Every call is appended to "$QVK_STUB_LOG".
name=$(basename "$0")
if [ -n "${QVK_STUB_LOG:-}" ]; then
  printf '%s %s\n' "$name" "$*" >>"$QVK_STUB_LOG"
fi
key=$(printf '%s %s' "$name" "$*" | tr -c 'A-Za-z0-9._-' '_')
f="${QVK_STUB_DIR:-/nonexistent}/$key"
if [ -f "$f" ]; then
  cat "$f"
  if [ -f "$f.exit" ]; then exit "$(cat "$f.exit")"; fi
  exit 0
fi
echo "stub: no fixture for: $name $*" >&2
exit 127
