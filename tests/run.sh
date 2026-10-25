#!/usr/bin/env bash
# Runs the script tests of plugins/dotclaude-dev/scripts. Usage: bash tests/run.sh
# Portable to bash 3.2 and BSD tools (macOS): no GNU-only options.
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
parser="$root/plugins/dotclaude-dev/scripts/pr-body-parse.jq"
fixtures="$root/tests/fixtures"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/dotclaude-tests-XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
passed=0
failed=0

# check <name> <actual-json> <expected-json>: equal after key sorting
check() {
  local name=$1 actual=$2 expected=$3
  : > "$tmp/diff"
  if jq -S . "$actual" > "$tmp/a" 2>/dev/null && jq -S . "$expected" > "$tmp/b" && diff "$tmp/a" "$tmp/b" > "$tmp/diff"; then
    echo "ok    $name"
    passed=$((passed + 1))
  else
    echo "FAIL  $name"
    sed 's/^/        /' "$tmp/diff"
    failed=$((failed + 1))
  fi
  return 0
}

for f in "$fixtures"/body/*.txt; do
  name=$(basename "$f" .txt)
  jq -Rs -f "$parser" "$f" > "$tmp/actual.json" 2>"$tmp/err" || cat "$tmp/err"
  check "body/$name" "$tmp/actual.json" "${f%.txt}.json"
done

# CRLF is generated, not stored: git and prettier would normalize a stored copy
awk '{printf "%s\r\n", $0}' "$fixtures/body/full-valid.txt" > "$tmp/crlf.txt"
jq -Rs -f "$parser" "$tmp/crlf.txt" > "$tmp/actual.json" 2>"$tmp/err" || cat "$tmp/err"
check "body/full-valid (CRLF)" "$tmp/actual.json" "$fixtures/body/full-valid.json"

echo "$passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
