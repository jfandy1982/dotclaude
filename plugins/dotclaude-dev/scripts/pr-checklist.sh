#!/usr/bin/env bash
# The PR merge checklist items of a repository that apply to the current branch.
#   pr-checklist.sh <remote> <default-branch>
#       prints one JSON line {state, items}: state "none" (no CLAUDE.md in the repository root, or no checklist heading),
#       "unusable" (heading found, but no table or a column is missing) or "ok"; items are the "Checklist item" cells of
#       the rows with at least one changed file (diff against <remote>/<default-branch> at the merge-base) matching their
#       "File pattern" cell, as raw markdown, in table order, exact duplicates collapsed to the first one.
#
# Only <repo-root>/CLAUDE.md is read, never a CLAUDE.md in a subfolder, a parent folder or another repository.
#
# Table format: a heading line "### PR merge checklist" starts the section. The heading must match exactly (trailing spaces
# are ignored, leading spaces or another level such as "####" are not); only the first such heading is used. The next
# heading of level 1 to 3 ends the section, deeper headings stay inside. Lines inside fenced code blocks (``` or ~~~) are
# ignored, so an example table in a fence is not the checklist; a fence ends only at a line of the same character that is at
# least as long as the opening one. The first markdown table of the section is the checklist:
# a block of consecutive lines that start with "|" (a trailing "|" is optional). Columns are found by their exact header
# text "File pattern" and "Checklist item", in any order; other columns are ignored. Cells are split on every "|" that
# is not escaped, also inside backticks: write "\|" for a literal pipe (the item keeps the "\|" as written). Rows with
# an empty pattern or an empty item are skipped.
#
# Pattern rules: the "File pattern" cell holds one or more patterns separated by commas (always, so {a,b} cannot be
# written). Each is trimmed, a leading and a trailing backtick are removed (so one pair around a comma list works too),
# then one leading "./" is removed. The rest goes to git as :(top,glob)<pattern>, so it is relative to the repository
# root and follows git's own glob rules:
#   package.json             exactly that file at the repository root
#   apps/api/migrations      everything below that directory (a bare directory name)
#   apps/**/migrations/*     direct children of any "migrations" folder below apps/ ("**" also matches zero folders)
#   apps/**/migrations/**    every file at any depth below such a folder
#   **/*.md, *.json          *.md at any depth; *.json at the root only ("*" never crosses "/")
# A leading "/", "!" or ":" is not special: such a pattern matches nothing. Git never rejects a pattern, so a typo is a
# silent non-match. Changed means added, changed or deleted; renames are not followed, so a file moved out of a folder
# matches through its old path and through its new path.
#
# Errors follow the contract in contract.sh (no gh call is made here).
# Portable to bash 3.2 and BSD tools (macOS): no GNU-only options.
set -u -o pipefail

SCRIPT="pr-checklist.sh"
SUBCOMMANDS='<remote> <default-branch>'
# shellcheck source=contract.sh
source "$(dirname "${BASH_SOURCE[0]}")/contract.sh"

# shortcut: several processes per row (about 10 ms, 300 rows took about 3 s), fine for the 5 to 20 rows of a real checklist; emit all rows from one jq call beyond that
main() {
  [[ $# -eq 2 ]] || usage
  local remote=$1 base=$2 top parsed state row item pattern out items="[]"
  local -a specs
  require_repo
  top=$(run_git "repository root" rev-parse --show-toplevel) || exit $?
  if [[ ! -f $top/CLAUDE.md ]]; then
    printf '%s\n' '{"state":"none","items":[]}'
    return 0
  fi
  parsed=$(jq -Rs -f "$(dirname "${BASH_SOURCE[0]}")/pr-checklist-parse.jq" "$top/CLAUDE.md" 2> /dev/null) ||
    die "checklist" "Cannot read the checklist table of $top/CLAUDE.md."
  state=$(printf '%s' "$parsed" | jq -r '.state')
  # no rows: nothing to ask git, so the remote-tracking branch is not needed
  if [[ $(printf '%s' "$parsed" | jq '.rows | length') -eq 0 ]]; then
    jq -nc --arg state "$state" '{state: $state, items: []}'
    return 0
  fi
  set_range "$remote" "$base"
  while IFS= read -r row; do
    item=$(printf '%s' "$row" | jq -r '.item')
    specs=()
    while IFS= read -r pattern; do
      specs+=(":(top,glob)$pattern")
    done < <(printf '%s' "$row" | jq -r '.patterns[]')
    # the parser drops rows without patterns; without this guard an empty array would break bash 3.2 under set -u, and git without a pathspec matches every changed file
    [[ ${#specs[@]} -gt 0 ]] || continue
    # the exit code of git diff does not tell a match from none: the output does
    out=$(run_git "changed files of $RANGE" -C "$top" diff "$RANGE" --name-only --no-renames -- "${specs[@]}") ||
      exit $?
    [[ -z $out ]] ||
      items=$(printf '%s' "$items" | jq -c --arg item "$item" 'if index($item) then . else . + [$item] end')
  done < <(printf '%s' "$parsed" | jq -c '.rows[]')
  jq -nc --arg state "$state" --argjson items "$items" '{state: $state, items: $items}'
  return 0
}

main "$@"
