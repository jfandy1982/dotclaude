# Error contract of the scripts that call gh or git (pr-data.sh, pr-create.sh, remote-host.sh, branch-diff.sh, pr-checklist.sh). Sourced, not run.
# The sourcing script sets SCRIPT and SUBCOMMANDS (for the usage message) and may set VERB (default "read", "create" for writes).
# On failure: nothing on stdout, one JSON line on stderr {error, exit, retryable, what, message}
# and a fixed exit code: 10 auth, 11 not_found, 12 rate_limited, 13 network, 1 other, 2 usage.
# shortcut: the cause is matched from the text of gh's error output, replace by a structured status if gh offers one.
# Portable to bash 3.2 and BSD tools (macOS): no GNU-only options.

HOST=""
OUT=""
VERB="read"

command -v jq > /dev/null 2>&1 || { echo "${SCRIPT:-gh-contract.sh}: jq is required" >&2; exit 1; }
ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/dotclaude-gh-XXXXXX") || exit 1
trap 'rm -f "$ERR_FILE"' EXIT

# emit_error <error> <exit-code> <retryable> <what> <message>
emit_error() {
  local error=$1 code=$2 retryable=$3 what=$4 message=$5
  jq -nc --arg error "$error" --argjson exit "$code" --argjson retryable "$retryable" \
    --arg what "$what" --arg message "$message" \
    '{error: $error, exit: $exit, retryable: $retryable, what: $what, message: $message}' >&2
  exit "$code"
}

# die <what> <message>: failures that are not a gh error
die() {
  local what=$1 message=$2
  emit_error other 1 false "$what" "$message"
  return 0
}

usage() {
  emit_error usage 2 false "arguments" "Wrong arguments. Usage: $SCRIPT $SUBCOMMANDS <arguments>, see the header of the script."
  return 0
}

# fail <what> <gh-exit-code>: classify the captured gh error output and exit
fail() {
  local what=$1 code=$2 first
  first=$(head -n 1 "$ERR_FILE")
  if [[ $code -eq 4 ]] || grep -qiE 'HTTP 401|gh auth login' "$ERR_FILE"; then
    emit_error auth 10 false "$what" "Not authenticated with $HOST. Run \`gh auth login --hostname $HOST\`, then re-run."
  fi
  if grep -qi 'rate limit' "$ERR_FILE"; then
    emit_error rate_limited 12 true "$what" "Could not $VERB $what: GitHub rate limit reached. Wait a few minutes, then re-run."
  fi
  if grep -qiE 'could not resolve to|no pull requests found|not found|HTTP 40[34]|HTTP 410' "$ERR_FILE"; then
    emit_error not_found 11 false "$what" "Could not $VERB $what: not found, or you have no access. Check the number and your access to the repository, then re-run."
  fi
  if grep -qiE 'error connecting to|no such host|could not resolve host|timeout|dial tcp|connection refused' "$ERR_FILE"; then
    emit_error network 13 true "$what" "Could not $VERB $what: cannot reach $HOST. Check the connection, then re-run."
  fi
  emit_error other 1 false "$what" "Could not $VERB $what: ${first:-gh exited with code $code}."
  return 0
}

# run_gh <what> <gh-arguments...>: stores stdout in OUT; a failed call never reaches the caller
run_gh() {
  local what=$1 code=0
  shift
  OUT=$(gh "$@" 2> "$ERR_FILE") || code=$?
  [[ $code -eq 0 ]] || fail "$what" "$code"
  return 0
}

# run_git <what> <git-arguments...>: runs git with its stdout passed through, so the caller can capture it or redirect it to a file.
# git errors are local (no login, no rate limit, no network) and not retryable: always "other", with git's own first error line in the message.
# A failed call never reaches the caller; inside $(...) the exit only ends the subshell, so write: x=$(run_git ...) || exit $?
run_git() {
  local what=$1 code=0 first
  shift
  git "$@" 2> "$ERR_FILE" || code=$?
  [[ $code -eq 0 ]] && return 0
  first=$(head -n 1 "$ERR_FILE")
  emit_error other 1 false "$what" "Could not $VERB $what: ${first:-git exited with code $code}."
  return 0
}

# write_file <dir> <name> <content>: writes via a temporary name, so a failed write leaves no partial file
write_file() {
  local dir=$1 name=$2 content=$3 tmp
  [[ -d $dir ]] || die "$name" "Folder $dir does not exist."
  tmp=$(mktemp "$dir/.tmp-XXXXXX") || die "$name" "Cannot write to $dir."
  if printf '%s\n' "$content" > "$tmp" && mv "$tmp" "$dir/$name"; then
    return 0
  fi
  rm -f "$tmp"
  die "$name" "Cannot write $dir/$name."
}
