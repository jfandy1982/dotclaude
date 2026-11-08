#!/usr/bin/env bash
# The setup both PR skills need before they collect anything, in one call.
#   preflight.sh <skill> <remote>
#       <skill> is create-pr or review-pr (the temporary folder prefix and the skill named in error messages),
#       <remote> the git remote whose repository is meant. In this order: inside a git repository, host of the remote,
#       login on that host, the repository behind the remote URL, then the temporary folder (last, so a failed run leaves none).
#       Writes <pr-dir>/preflight.json and prints the same JSON on one line:
#       {skill, remote, remoteUrl, host, username, repoUrl, repoPath, defaultBranch, prDir}
# Other scripts read host, repoUrl and repoPath from <pr-dir>/preflight.json through load_preflight in contract.sh.
# Errors follow the contract in contract.sh.
# Portable to bash 3.2 and BSD tools (macOS): no GNU-only options.
set -u -o pipefail

SCRIPT="preflight.sh"
SUBCOMMANDS='<skill> <remote>'
# shellcheck source=contract.sh
source "$(dirname "${BASH_SOURCE[0]}")/contract.sh"

main() {
  [[ $# -eq 2 ]] || usage
  local skill=$1 remote=$2 dir info remote_url host username repo default_branch json
  [[ $skill == create-pr || $skill == review-pr ]] || usage
  SKILL=$skill
  require_repo
  info=$(bash "$(dirname "${BASH_SOURCE[0]}")/remote-host.sh" "$remote") || exit $?
  remote_url=${info%%$'\n'*}
  host=${info#*$'\n'}
  HOST=$host
  run_gh "the login on $host" api user --hostname "$host" --jq '.login'
  username=$OUT
  run_gh "repository $remote_url" repo view "$remote_url" --json url,nameWithOwner,defaultBranchRef
  repo=$OUT
  default_branch=$(printf '%s' "$repo" | jq -r '.defaultBranchRef.name // empty') ||
    die "repository $remote_url" "Cannot read the repository returned by gh."
  [[ -n $default_branch ]] || die "repository $remote_url" "The repository has no default branch."
  dir=$(mktemp -d "$TEMP_BASE/$skill-XXXXXX" 2> "$ERR_FILE") ||
    die "temporary folder" "Cannot create a temporary folder in $TEMP_BASE: $(head -n 1 "$ERR_FILE"). Make it writable for your user or set TMPDIR to another folder, then $(rerun)."
  json=$(printf '%s' "$repo" | jq -c --arg skill "$skill" --arg remote "$remote" --arg remoteUrl "$remote_url" --arg host "$host" \
    --arg username "$username" --arg prDir "$dir" --arg defaultBranch "$default_branch" \
    '{skill: $skill, remote: $remote, remoteUrl: $remoteUrl, host: $host, username: $username, repoUrl: .url, repoPath: .nameWithOwner, defaultBranch: $defaultBranch, prDir: $prDir}') ||
    die "repository $remote_url" "Cannot read the repository returned by gh."
  write_file "$dir" preflight.json "$json"
  printf '%s\n' "$json"
  return 0
}

main "$@"
