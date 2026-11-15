#!/bin/sh
# .claude/check.sh: the one command that decides whether a ticket may land.
# The agent harness (merge.sh) runs it in the main checkout on the merged tree before every merge commit.
# It is the offline half of .github/workflows/ci.yml: build with tests, no warnings, the suite.
set -e
log=$(mktemp)
swift build --build-tests >"$log" 2>&1 || { cat "$log"; exit 1; }
if grep -E '^/.*warning:' "$log"; then echo "check: the build produced warnings; the standing rule is zero" >&2; exit 1; fi
swift test
