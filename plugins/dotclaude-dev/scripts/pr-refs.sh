#!/usr/bin/env bash
# Fetches what a review of a PR needs from git and finds its merge base.
#   pr-refs.sh <pr-dir>
#       reads number, headRefOid and baseRefName from <pr-dir>/pr.json and the remote from <pr-dir>/preflight.json, then
#       fetches the PR head (pull/<number>/head), checks that the commit pr.json names is part of it (it is not after a force-push),
#       fetches the base branch to refs/remotes/<remote>/<base> and prints {mergeBase}: the commit the PR was cut from,
#       seen from the base branch as it is now (what GitHub shows). The checked-out branch and the working tree stay as they are.
# The values come from pr.json and are checked here (number, commit id, ref name), so no text from the PR ever reaches a shell command in the skill.
# Errors follow the contract in contract.sh (no gh call is made here).
# Portable to bash 3.2 and BSD tools (macOS): no GNU-only options.
set -u -o pipefail

SCRIPT="pr-refs.sh"
SUBCOMMANDS='<pr-dir>'
# shellcheck source=contract.sh
source "$(dirname "${BASH_SOURCE[0]}")/contract.sh"

main() {
  [[ $# -eq 1 ]] || usage
  local dir=$1 remote values number head base merge_base
  require_repo
  load_preflight "$dir"
  remote=$(jq -r '.remote // empty' "$dir/preflight.json" 2> /dev/null)
  [[ -n $remote ]] || die "preflight.json" "$dir/preflight.json names no remote. Run preflight first."
  [[ -f $dir/pr.json ]] || die "pr.json" "Folder $dir has no pr.json. Fetch the PR first."
  values=$(jq -r '(.number | @text), (.headRefOid // ""), (.baseRefName // "")' "$dir/pr.json" 2> /dev/null) ||
    die "pr.json" "Cannot read $dir/pr.json."
  { IFS= read -r number; IFS= read -r head; IFS= read -r base; } <<< "$values"
  [[ $number =~ ^[0-9]+$ ]] || die "pr.json" "$dir/pr.json has no usable PR number."
  [[ $head =~ ^[0-9a-f]{40,64}$ ]] || die "pr.json" "$dir/pr.json has no usable head commit."
  git check-ref-format "refs/heads/$base" 2> /dev/null || die "pr.json" "$dir/pr.json has no usable base branch name."
  VERB=fetch
  run_git "the head of PR $number from $remote" fetch "$remote" "pull/$number/head"
  [[ $(git cat-file -t "$head" 2> /dev/null) == commit ]] ||
    die "head of PR $number" "PR $number was force-pushed after its data was fetched: commit $head is gone. Please $(rerun)."
  run_git "base branch $base from $remote" fetch "$remote" "+refs/heads/$base:refs/remotes/$remote/$base"
  merge_base=$(git merge-base "$head" "refs/remotes/$remote/$base" 2> /dev/null) ||
    die "merge base" "Could not determine the merge base of PR $number with $base."
  jq -nc --arg mergeBase "$merge_base" '{mergeBase: $mergeBase}'
  return 0
}

main "$@"
