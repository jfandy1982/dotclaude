#!/usr/bin/env bash
# Host of a git remote, cut offline from its URL.
#   remote-host.sh <remote>
#       prints two lines: the URL of the remote and its host
#   remote-host.sh --url <url>
#       prints the host of the URL
# Understands https://, http://, git@host:path, ssh://git@host:port/path and user@ in an https URL.
# Errors follow the contract in gh-contract.sh; a remote that does not exist is "other", not "not_found" (11 means GitHub said so).
# Portable to bash 3.2 and BSD tools (macOS): no GNU-only options.
set -u -o pipefail

SCRIPT="remote-host.sh"
SUBCOMMANDS='<remote>|--url'
# shellcheck source=gh-contract.sh
source "$(dirname "${BASH_SOURCE[0]}")/gh-contract.sh"

# host_of <url>: prints the host, nothing when there is none
host_of() {
  printf '%s\n' "$1" | sed -E 's#^[a-z+]+://##; s#^[^@/]*@##; s#[:/].*##'
  return 0
}

main() {
  local url host
  case $# in
    1) [[ $1 != --url ]] || usage
       url=$(git remote get-url "$1" 2> /dev/null) || die "remote $1" "No remote named $1 in this repository."
       ;;
    2) [[ $1 == --url ]] || usage
       url=$2
       ;;
    *) usage ;;
  esac
  host=$(host_of "$url")
  [[ -n $host ]] || die "remote host" "Cannot read a host from the URL $url."
  [[ $# -eq 2 ]] || printf '%s\n' "$url"
  printf '%s\n' "$host"
  return 0
}

main "$@"
