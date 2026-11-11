#!/usr/bin/env bash
# Host of a git remote, cut offline from its URL.
#   remote-host.sh <remote>
#       prints two lines: the URL of the remote (without user and password when it is http or https) and its host
#   remote-host.sh --url <url>
#       prints the host of the URL
# Understands https://, http://, git@host:path, ssh://git@host:port/path and user@ in an https URL.
# Errors follow the contract in contract.sh; a remote that does not exist is "other", not "not_found" (11 means GitHub said so).
# Portable to bash 3.2 and BSD tools (macOS): no GNU-only options.
set -u -o pipefail

SCRIPT="remote-host.sh"
SUBCOMMANDS='<remote>|--url'
# shellcheck source=contract.sh
source "$(dirname "${BASH_SOURCE[0]}")/contract.sh"

# host_of <url>: prints the host, nothing when there is none
host_of() {
  local url=$1
  printf '%s\n' "$url" | sed -E 's#^[a-z+]+://##; s#^[^@/]*@##; s#[:/].*##'
  return 0
}

main() {
  local count=$# first=${1:-} second=${2:-} url host
  case $count in
    1) [[ $first != --url ]] || usage
       url=$(git remote get-url "$first" 2> /dev/null) || die "remote $first" "No remote named $first in this repository."
       ;;
    2) [[ $first == --url ]] || usage
       url=$second
       ;;
    *) usage ;;
  esac
  # user and password of an http(s) URL can be a token: they never leave this script (the user of an ssh URL is no secret)
  url=$(printf '%s\n' "$url" | sed -E 's#^(https?://)[^/]*@#\1#')
  host=$(host_of "$url")
  [[ -n $host ]] || die "remote host" "Cannot read a host from the URL $url."
  [[ $count -eq 2 ]] || printf '%s\n' "$url"
  printf '%s\n' "$host"
  return 0
}

main "$@"
