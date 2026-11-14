#!/usr/bin/env bash
# GitHub calls of create-pr behind one error contract (contract.sh).
# Host and repository URL come from <pr-dir>/preflight.json (written by preflight.sh, which also reads the repository).
#   pr-create.sh labels <pr-dir>
#       gh label list (limit 50: the target repos have about 25 labels, raise it if a repo exceeds 50);
#       writes <pr-dir>/labels.json (all labels), prints {mode, labels}:
#       "taxonomy" with the labels prefixed type: or aspect:, or "fallback" with all labels when there are none
#   pr-create.sh list-open-prs <pr-dir>
#       prints the open PRs of this repository whose head is the branch name on the remote (remoteBranch of
#       <pr-dir>/preflight.json, written by preflight.sh create-pr): [{number, title, url}]. A PR from a fork that
#       happens to use the same head name does not count.
#   pr-create.sh create <pr-dir> <yes|no> [<label>...]
#       reads <pr-dir>/title.txt and <pr-dir>/body.txt, runs gh pr create (yes = draft), prints the PR URL
# Portable to bash 3.2 and BSD tools (macOS): no GNU-only options.
set -u -o pipefail

SCRIPT="pr-create.sh"
SUBCOMMANDS='labels|list-open-prs|create'
# shellcheck source=contract.sh
source "$(dirname "${BASH_SOURCE[0]}")/contract.sh"

cmd_labels() {
  local dir=$1 result
  load_preflight "$dir"
  run_gh "labels of $REPO_URL" label list --repo "$REPO_URL" --json name,description --limit 50
  result=$(printf '%s' "$OUT" | jq -c '
    [.[] | select(.name | startswith("type:") or startswith("aspect:"))] as $taxonomy
    | if ($taxonomy | length) > 0 then {mode: "taxonomy", labels: $taxonomy} else {mode: "fallback", labels: .} end') ||
    die "labels of $REPO_URL" "Cannot read the labels returned by gh."
  write_file "$dir" labels.json "$OUT"
  printf '%s\n' "$result"
  return 0
}

cmd_list_open_prs() {
  local dir=$1 branch
  load_preflight "$dir"
  branch=$(jq -r '.remoteBranch // empty' "$dir/preflight.json" 2> /dev/null)
  [[ -n $branch ]] || die "preflight.json" "$dir/preflight.json names no remote branch. Run preflight.sh create-pr first."
  # shortcut: gh pr list --json isCrossRepository (as in gh pr view) is assumed, not run against a real gh; drop the filter if gh refuses the field
  run_gh "open PRs of branch $branch" pr list --repo "$REPO_URL" --head "$branch" --state open --json number,title,url,isCrossRepository
  printf '%s' "$OUT" | jq -c '[.[] | select(.isCrossRepository | not) | {number, title, url}]' ||
    die "open PRs of branch $branch" "Cannot read the PR list returned by gh."
  return 0
}

cmd_create() {
  local dir=$1 draft=$2 title label
  local -a args
  shift 2
  [[ $draft == yes || $draft == no ]] || usage
  load_preflight "$dir"
  VERB=create
  [[ -f $dir/title.txt ]] || die "title" "Folder $dir has no title.txt. Write the title first."
  [[ -f $dir/body.txt ]] || die "body" "Folder $dir has no body.txt. Write the body first."
  title=$(cat "$dir/title.txt")
  [[ -n $title ]] || die "title" "The title in $dir/title.txt is empty."
  args=(pr create --repo "$REPO_URL" --assignee @me --title "$title" --body-file "$dir/body.txt")
  [[ $draft == no ]] || args+=(--draft)
  for label in "$@"; do
    args+=(--label "$label")
  done
  run_gh "the PR" "${args[@]}"
  printf '%s\n' "$OUT"
  return 0
}

main() {
  local cmd=${1:-}
  [[ $# -gt 0 ]] && shift
  case $cmd in
    labels) [[ $# -eq 1 ]] || usage; cmd_labels "$@" ;;
    list-open-prs) [[ $# -eq 1 ]] || usage; cmd_list_open_prs "$@" ;;
    create) [[ $# -ge 2 ]] || usage; cmd_create "$@" ;;
    *) usage ;;
  esac
  return $?
}

main "$@"
