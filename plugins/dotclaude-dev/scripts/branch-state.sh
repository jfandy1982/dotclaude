#!/usr/bin/env bash
# The state of the current branch against its upstream, for create-pr.
#   branch-state.sh [create-pr]
#       prints {branch, remote, remoteBranch}: the current branch, the remote its upstream lives on and the branch name there
#       (it can differ from the local name). Remote and branch come from the git configuration, not from the text of @{u}, so a
#       remote name with a "/" works and an upstream that is a local branch is told apart. The remote is fetched first.
#       Stops with a message when HEAD is detached, the branch has no upstream on a remote, the fetch fails,
#       or the branch is behind its upstream or has commits that are not on it yet (behind is checked first).
#       The optional skill names the command to re-run in the messages.
# Errors follow the contract in contract.sh (no gh call is made here).
# Portable to bash 3.2 and BSD tools (macOS): no GNU-only options.
set -u -o pipefail

SCRIPT="branch-state.sh"
SUBCOMMANDS='[create-pr]'
# shellcheck source=contract.sh
source "$(dirname "${BASH_SOURCE[0]}")/contract.sh"

main() {
  local branch remote merge remote_branch counts behind ahead
  [[ $# -le 1 ]] || usage
  case ${1:-} in
    create-pr) SKILL=$1 ;;
    "") ;;
    *) usage ;;
  esac
  require_repo
  branch=$(run_git "the current branch" branch --show-current) || exit $?
  [[ -n $branch ]] || die "branch" "Not on a branch. Check out a branch, then $(rerun)."
  remote=$(git config --get "branch.$branch.remote" 2> /dev/null || true)
  merge=$(git config --get "branch.$branch.merge" 2> /dev/null || true)
  [[ -n $remote && -n $merge ]] ||
    die "upstream" "Branch $branch has no remote tracking branch. Push it first (\`git push -u origin $branch\`), then $(rerun)."
  [[ $remote != . ]] ||
    die "upstream" "The upstream of branch $branch is the local branch ${merge#refs/heads/}, not a branch on a remote. Push $branch to a remote first (\`git push -u origin $branch\`), then $(rerun)."
  git remote get-url "$remote" > /dev/null 2>&1 || die "remote $remote" "No remote named $remote in this repository."
  [[ $merge == refs/heads/* ]] || die "upstream" "The upstream of branch $branch ($merge) is not a branch."
  remote_branch=${merge#refs/heads/}
  VERB=fetch
  run_git "$remote" fetch "$remote"
  git rev-parse --verify --quiet "refs/remotes/$remote/$remote_branch^{commit}" > /dev/null 2>&1 ||
    die "upstream" "The upstream branch $remote/$remote_branch does not exist. Push $branch again (\`git push -u $remote $branch\`), then $(rerun)."
  counts=$(run_git "ahead and behind of $branch" rev-list --left-right --count "refs/remotes/$remote/$remote_branch...HEAD") || exit $?
  IFS=$'\t' read -r behind ahead <<< "$counts"
  [[ $behind -eq 0 ]] ||
    die "branch" "Local branch is behind $remote/$remote_branch — pull the latest changes (\`git pull\`), then $(rerun)."
  [[ $ahead -eq 0 ]] ||
    die "branch" "Local branch has commits that are not on $remote/$remote_branch yet — push first (\`git push\`), then $(rerun)."
  jq -nc --arg branch "$branch" --arg remote "$remote" --arg remoteBranch "$remote_branch" '{branch: $branch, remote: $remote, remoteBranch: $remoteBranch}'
  return 0
}

main "$@"
