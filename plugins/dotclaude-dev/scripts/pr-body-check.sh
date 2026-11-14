#!/usr/bin/env bash
# Checks the body create-pr wrote against the files that changed.
#   pr-body-check.sh <pr-dir>
#       reads <pr-dir>/body.txt and <pr-dir>/file-table.json (written by branch-diff.sh files) and prints the result of
#       pr-body-parse.jq plus "uncovered": the changed paths that no entry of the File risk section names (see pr-body-coverage.jq).
#       Not checked: a file named twice, the count in a group's "(N files)", a path that contains a backtick (it cannot be written as an entry).
# Errors follow the contract in contract.sh (no gh call is made here).
# Portable to bash 3.2 and BSD tools (macOS): no GNU-only options.
set -u -o pipefail

SCRIPT="pr-body-check.sh"
SUBCOMMANDS='<pr-dir>'
# shellcheck source=contract.sh
source "$(dirname "${BASH_SOURCE[0]}")/contract.sh"

main() {
  [[ $# -eq 1 ]] || usage
  local dir=$1 here parsed
  here=$(dirname "${BASH_SOURCE[0]}")
  [[ -f $dir/body.txt ]] || die "body.txt" "Folder $dir has no body.txt. Write the body first."
  [[ -f $dir/file-table.json ]] || die "file-table.json" "Folder $dir has no file-table.json. Run branch-diff.sh files first."
  parsed=$(jq -Rs -f "$here/pr-body-parse.jq" "$dir/body.txt") || die "body.txt" "Cannot read the body in $dir/body.txt."
  printf '%s' "$parsed" | jq -c --argjson table "$(cat "$dir/file-table.json")" -f "$here/pr-body-coverage.jq" 2> /dev/null ||
    die "file-table.json" "Cannot read the file table in $dir/file-table.json."
  return 0
}

main "$@"
