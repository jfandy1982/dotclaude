# Error contract of the scripts that call gh or git (preflight.sh, pr-data.sh, pr-create.sh, remote-host.sh, branch-diff.sh, pr-checklist.sh). Sourced, not run.
# The sourcing script sets SCRIPT and SUBCOMMANDS (for the usage message) and may set VERB (default "read", "create" for writes).
# On failure: nothing on stdout, one JSON line on stderr {error, exit, retryable, what, message}
# and a fixed exit code: 10 auth, 11 not_found, 12 rate_limited, 13 network, 1 other, 2 usage.
# Everything the scripts write lives under TEMP_BASE ($TMPDIR/dotclaude-dev) and is never deleted by them: the folders have unique names, and cleaning the temporary folder is left to the OS.
# SKILL (set by load_preflight, or by the script itself) names the skill in the "then re-run" hint of the messages; empty keeps the plain "re-run".
# shortcut: the cause is matched from the text of gh's error output, replace by a structured status if gh offers one.
# Portable to bash 3.2 and BSD tools (macOS): no GNU-only options.

HOST=""
OUT=""
VERB="read"
RANGE=""
SKILL=""
REPO_URL=""
REPO_PATH=""

command -v jq > /dev/null 2>&1 || { echo "${SCRIPT:-contract.sh}: jq is required" >&2; exit 1; }
TEMP_BASE="${TMPDIR:-/tmp}/dotclaude-dev"
ERR_FILE=""

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

# rerun: prints "re-run", followed by the skill as a command when SKILL is set
rerun() {
  if [[ -n $SKILL ]]; then
    printf 're-run `/%s`' "$SKILL"
  else
    printf 're-run'
  fi
  return 0
}

usage() {
  emit_error usage 2 false "arguments" "Wrong arguments. Usage: $SCRIPT $SUBCOMMANDS, see the header of the script."
  return 0
}

# fail <what> <gh-exit-code>: classify the captured gh error output and exit
fail() {
  local what=$1 code=$2 first
  first=$(head -n 1 "$ERR_FILE")
  if [[ $code -eq 4 ]] || grep -qiE 'HTTP 401|gh auth login' "$ERR_FILE"; then
    emit_error auth 10 false "$what" "Not authenticated with $HOST. Run \`gh auth login --hostname $HOST\`, then $(rerun)."
  fi
  if grep -qiE 'rate limit|HTTP 429' "$ERR_FILE"; then
    emit_error rate_limited 12 true "$what" "Could not $VERB $what: GitHub rate limit reached. Wait a few minutes, then $(rerun)."
  fi
  if grep -qiE 'could not resolve to|no pull requests found|not found|HTTP 40[34]|HTTP 410' "$ERR_FILE"; then
    if [[ $VERB == create ]]; then
      emit_error not_found 11 false "$what" "Could not $VERB $what: something it needs was not found, or you have no access. Check the labels, the branch and your access to the repository, then $(rerun)."
    fi
    emit_error not_found 11 false "$what" "Could not $VERB $what: not found, or you have no access. Check the number and your access to the repository, then $(rerun)."
  fi
  if grep -qiE 'error connecting to|no such host|could not resolve host|timeout|dial tcp|connection refused' "$ERR_FILE"; then
    # shortcut: a timeout after GitHub accepted the request would make a re-run create a second PR; whether gh can time out that way is unverified, so a create is never retryable
    if [[ $VERB == create ]]; then
      emit_error network 13 false "$what" "Could not $VERB $what: cannot reach $HOST. The PR may have been created anyway: check \`gh pr list --head <branch>\` before you $(rerun)."
    fi
    emit_error network 13 true "$what" "Could not $VERB $what: cannot reach $HOST. Check the connection, then $(rerun)."
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

# require_repo: dies unless the working directory is inside a git work tree
require_repo() {
  [[ $(git rev-parse --is-inside-work-tree 2> /dev/null) == true ]] ||
    die "repository" "Not inside a git repository. Run from a clone of the target repo, then $(rerun)."
  return 0
}

# load_preflight <dir>: sets HOST, REPO_URL, REPO_PATH and SKILL from <dir>/preflight.json, which preflight.sh wrote
load_preflight() {
  local dir=$1 file out
  file="$dir/preflight.json"
  [[ -f $file ]] || die "preflight.json" "Folder $dir has no preflight.json. Run preflight first."
  out=$(jq -r '(.host // ""), (.repoUrl // ""), (.repoPath // ""), (.skill // "")' "$file" 2> /dev/null) ||
    die "preflight.json" "Cannot read $file."
  { IFS= read -r HOST; IFS= read -r REPO_URL; IFS= read -r REPO_PATH; IFS= read -r SKILL; } <<< "$out"
  [[ -n $HOST && -n $REPO_URL && -n $REPO_PATH ]] || die "preflight.json" "$file lacks host, repoUrl or repoPath."
  return 0
}

# set_range <remote> <default-branch>: sets RANGE to the three-dot range (the changes since the merge-base), dies when the remote-tracking branch does not exist
set_range() {
  local remote=$1 base=$2
  run_git "repository" rev-parse --git-dir > /dev/null
  git rev-parse --verify --quiet "refs/remotes/$remote/$base^{commit}" > /dev/null 2>&1 ||
    die "$remote/$base" "No remote-tracking branch $remote/$base in this repository."
  RANGE="$remote/$base...HEAD"
  return 0
}

# setup_scratch: creates TEMP_BASE and the file ERR_FILE for the stderr of gh and git calls; runs once when the file is sourced
setup_scratch() {
  local reason
  reason=$(mkdir -p -m 700 "$TEMP_BASE" 2>&1) ||
    die "temporary folder" "Cannot create the temporary folder $TEMP_BASE: $(printf '%s' "$reason" | head -n 1). Make its parent writable for your user or set TMPDIR to another folder, then $(rerun)."
  ERR_FILE=$(mktemp "$TEMP_BASE/stderr-XXXXXX" 2> /dev/null) ||
    die "temporary folder" "Cannot create a file in the temporary folder $TEMP_BASE. Make it writable for your user or set TMPDIR to another folder, then $(rerun)."
  return 0
}
setup_scratch
