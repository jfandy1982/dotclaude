#!/usr/bin/env bash
# The setup both PR skills need before they collect anything, in one call.
#   preflight.sh create-pr
#   preflight.sh review-pr <remote>
#       The skill is the temporary folder prefix and the skill named in error messages. review-pr names the git remote whose
#       repository is meant. create-pr finds its remote itself: branch-state.sh checks the branch against its upstream first
#       (no upstream, behind, ahead), and the remote of the upstream is the one meant.
#       In this order: inside a git repository, (create-pr only) the branch checks, host of the remote, login on that host,
#       the repository behind the remote URL, (create-pr only) the branch is not the default branch, then the temporary folder
#       (last, so a failed run leaves none).
#       Writes <pr-dir>/preflight.json and prints the same JSON on one line:
#       {skill, remote, remoteUrl, host, username, repoUrl, repoPath, defaultBranch, prDir}
#       plus {branch, remoteBranch} for create-pr (the current branch and its name on the remote)
# Other scripts read host, repoUrl and repoPath from <pr-dir>/preflight.json through load_preflight in contract.sh.
# Errors follow the contract in contract.sh.
# Portable to bash 3.2 and BSD tools (macOS): no GNU-only options.
set -u -o pipefail

SCRIPT="preflight.sh"
SUBCOMMANDS='create-pr | review-pr <remote>'
# shellcheck source=contract.sh
source "$(dirname "${BASH_SOURCE[0]}")/contract.sh"

main() {
  local skill=${1:-} second=${2:-} remote="" branch="" remote_branch="" dir state info remote_url host username repo default_branch json
  case $skill in
    create-pr) [[ $# -eq 1 ]] || usage ;;
    review-pr) [[ $# -eq 2 ]] || usage; remote=$second ;;
    *) usage ;;
  esac
  SKILL=$skill
  require_repo
  if [[ $skill == create-pr ]]; then
    state=$(bash "$(dirname "${BASH_SOURCE[0]}")/branch-state.sh" create-pr) || exit $?
    { IFS= read -r branch; IFS= read -r remote; IFS= read -r remote_branch; } < <(printf '%s' "$state" | jq -r '.branch, .remote, .remoteBranch')
  fi
  info=$(bash "$(dirname "${BASH_SOURCE[0]}")/remote-host.sh" "$remote") || exit $?
  remote_url=${info%%$'\n'*}
  host=${info#*$'\n'}
  HOST=$host
  run_gh "the login on $host" api user --hostname "$host" --jq '.login'
  username=$OUT
  run_gh "repository $remote_url" repo view "$remote_url" --json url,nameWithOwner,defaultBranchRef
  repo=$OUT
  default_branch=$(printf '%s' "$repo" | jq -r '.defaultBranchRef.name // empty' 2> /dev/null) ||
    die "repository $remote_url" "Cannot read the repository returned by gh."
  [[ -n $default_branch ]] || die "repository $remote_url" "The repository has no default branch."
  [[ $skill != create-pr || $branch != "$default_branch" ]] ||
    die "branch" "Branch $branch is the default branch — create a feature branch first, then $(rerun)."
  dir=$(mktemp -d "$TEMP_BASE/$skill-XXXXXX" 2> "$ERR_FILE") ||
    die "temporary folder" "Cannot create a temporary folder in $TEMP_BASE: $(head -n 1 "$ERR_FILE"). Make it writable for your user or set TMPDIR to another folder, then $(rerun)."
  json=$(printf '%s' "$repo" | jq -c --arg skill "$skill" --arg remote "$remote" --arg remoteUrl "$remote_url" --arg host "$host" \
    --arg username "$username" --arg prDir "$dir" --arg defaultBranch "$default_branch" --arg branch "$branch" --arg remoteBranch "$remote_branch" \
    '{skill: $skill, remote: $remote, remoteUrl: $remoteUrl, host: $host, username: $username, repoUrl: .url, repoPath: .nameWithOwner, defaultBranch: $defaultBranch, prDir: $prDir}
      + (if $skill == "create-pr" then {branch: $branch, remoteBranch: $remoteBranch} else {} end)' 2> /dev/null) ||
    die "repository $remote_url" "Cannot read the repository returned by gh."
  write_file "$dir" preflight.json "$json"
  printf '%s\n' "$json"
  return 0
}

main "$@"
