#!/usr/bin/env bash
# Runs the script tests of plugins/dotclaude-dev/scripts. Usage: bash tests/run.sh
# Portable to bash 3.2 and BSD tools (macOS): no GNU-only options.
#
# Index: one section per line, in file order. A section starts with "# ---- <name> ----" below; the last test checks that every name is listed here.
#   PR body parser
#       pr-body-parse.jq: sections, File risk buckets, Closes and merge danger of a PR body
#   worktree state
#       worktree-state.jq: resumed, prune and previous head of a review worktree
#   pr-data.sh: pr and refs
#       pr-data.sh pr: PR fields, base commit, computed checks, argument validation
#   pr-data.sh: issue, ci, feedback
#       pr-data.sh issue, alert, ci, feedback: files written, one-line outputs, failures
#   the fake gh itself
#       tests/stub/gh.sh: required flags (exit 97), api answers by endpoint
#   error contract (contract.sh)
#       contract.sh: error classes, exit codes, retryable, the phrases of gh failures, write_file
#   remote-host.sh
#       remote-host.sh: host and URL of a remote, credentials dropped, scheme in any case
#   pr-create.sh
#       pr-create.sh labels, list-open-prs, create: files written, flags, failure classes
#   branch-diff.sh
#       branch-diff.sh: diff files, file table, generated files, renames, one call per folder
#   pr-body-check.sh
#       pr-body-check.sh: changed files that the File risk section does not name
#   pr-checklist-parse.jq
#       pr-checklist-parse.jq: the PR merge checklist table (fences, columns, cells)
#   pr-checklist.sh
#       pr-checklist.sh: rows matched against the changed files with git pathspec matching
#   git failures: run_git puts git's own reason into the message
#       contract.sh run_git and require_repo as seen from the git scripts
#   branch-state.sh
#       branch-state.sh: upstream from the git config, behind, ahead, detached HEAD
#   preflight.sh
#       preflight.sh: setup of create-pr and review-pr, folder only at the end, login, repository
#   contract.sh: require_repo, load_preflight, the skill hint
#       contract.sh: require_repo, load_preflight, the skill named in messages
#   pr-refs.sh
#       pr-refs.sh: PR head and base fetch, merge base, force-push, odd branch names
#   skills: the PR skills call their scripts, agree with each other and keep the old defects out
#       the skills call their scripts, shared rules are equal in both, old defects stay out, READMEs and manifests agree
#   skills: manual-only, so the model never starts them from a loose description match
#       disable-model-invocation in all three skills
#   skills/create-pr: --issue and --alert arguments
#       create-pr argument-hint and the number cleaning command
#   the index at the top of this file
#       every section of this file is listed here
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
parser="$root/plugins/dotclaude-dev/scripts/pr-body-parse.jq"
script="$root/plugins/dotclaude-dev/scripts/pr-data.sh"
fixtures="$root/tests/fixtures"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/dotclaude-tests-XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
# the scripts write under $TMPDIR/dotclaude-dev and never delete it: the tests keep that inside their own folder
export TMPDIR="$tmp"
passed=0
failed=0
SEED_PR_JSON=""
# the contract wording of require_repo, checked in several sections
not_in_repo="Not inside a git repository"

# The fake gh replaces the real one in every bash process started below
source "$root/tests/stub/gh.sh"
export -f gh
source "$root/tests/stub/git.sh"
export -f git

# report <name> <ok|fail> [detail]
report() {
  local name=$1 status=$2 detail=${3:-}
  if [[ $status == ok ]]; then
    echo "ok    $name"
    passed=$((passed + 1))
  else
    echo "FAIL  $name"
    [[ -z $detail ]] || printf '%s\n' "$detail" | sed 's/^/        /'
    failed=$((failed + 1))
  fi
  return 0
}

# check <name> <actual-json> <expected-json>: equal after key sorting
check() {
  local name=$1 actual=$2 expected=$3
  : > "$tmp/diff"
  if jq -S . "$actual" > "$tmp/a" 2> /dev/null && jq -S . "$expected" > "$tmp/b" && diff "$tmp/a" "$tmp/b" > "$tmp/diff"; then
    report "$name" ok
  else
    report "$name" fail "$(cat "$tmp/diff")"
  fi
  return 0
}

# expect_text <name> <file> <expected-text>: file content equals the text, ignoring trailing newlines
expect_text() {
  local name=$1 file=$2 want=$3 got
  got=$(cat "$file")
  if [[ $got == "$want" ]]; then
    report "$name" ok
  else
    report "$name" fail "want: $want"$'\n'"got:  $got"
  fi
  return 0
}

# expect_empty <name> <dir>: a failed run leaves no file behind (the seeded preflight.json is not the run's)
expect_empty() {
  local name=$1 dir=$2 listing
  listing=$(ls -A "$dir" | grep -v '^preflight\.json$' || true)
  if [[ -z $listing ]]; then
    report "$name" ok
  else
    report "$name" fail "files left: $listing"
  fi
  return 0
}

# expect_absent <name> <file>
expect_absent() {
  local name=$1 file=$2
  if [[ ! -e $file ]]; then
    report "$name" ok
  else
    report "$name" fail "exists: $file"
  fi
  return 0
}

# new_stub: a fresh folder of canned answers for the fake gh, with the flags each call must carry (a wrong flag fails the call, see stub/gh.sh)
new_stub() {
  local dir repo_flag='--repo'
  dir=$(mktemp -d "$tmp/stub-XXXXXX") || return 1
  printf '%s\n' "$repo_flag" '--json number,url,title,body,labels,files' > "$dir/pr-view.args"
  printf '%s\n' "$repo_flag" '--json number,title,state,body,labels' > "$dir/issue-view.args"
  printf '%s\n' "$repo_flag" '--json name,description' '--limit 50' > "$dir/label-list.args"
  printf '%s\n' "$repo_flag" '--head' '--state open' '--json number,title,url' > "$dir/pr-list.args"
  printf '%s\n' "$repo_flag" '--assignee @me' '--title' '--body-file' > "$dir/pr-create.args"
  printf '%s\n' '--json url,nameWithOwner,defaultBranchRef' > "$dir/repo-view.args"
  printf '%s\n' '--hostname' > "$dir/api.args"
  printf '%s\n' "$dir"
  return 0
}

# fail_stub <stub-dir> <command> <exit-code> <stderr-text> [stdout-text]
fail_stub() {
  local dir=$1 name=$2 code=$3 text=$4 body=${5:-}
  printf '%s\n' "$text" > "$dir/$name.err"
  printf '%s\n' "$code" > "$dir/$name.exit"
  [[ $# -lt 5 ]] || printf '%s\n' "$body" > "$dir/$name.out"
  return 0
}

# seed_preflight <dir>: the preflight.json that preflight.sh would have written (no skill, so messages keep the plain hint)
seed_preflight() {
  local dir=$1
  printf '%s\n' '{"host":"github.example.local","repoUrl":"https://github.example.local/o/r","repoPath":"o/r"}' > "$dir/preflight.json"
  return 0
}

# new_work: a fresh folder with a seeded preflight.json
new_work() {
  local dir
  dir=$(mktemp -d "$tmp/work-XXXXXX")
  seed_preflight "$dir"
  printf '%s\n' "$dir"
  return 0
}

# run_data <stub-dir> <arguments...>: runs pr-data.sh with the fake gh; the word PR_DIR in the arguments becomes a fresh folder
# with a seeded preflight.json (not when NO_PREFLIGHT is set), and a pr.json copied from SEED_PR_JSON when that is set
run_data() {
  local stub=$1 arg
  local -a args=()
  shift
  PR_DIR=$(mktemp -d "$tmp/work-XXXXXX")
  [[ -n ${NO_PREFLIGHT:-} ]] || seed_preflight "$PR_DIR"
  [[ -z $SEED_PR_JSON ]] || cp "$SEED_PR_JSON" "$PR_DIR/pr.json"
  for arg in "$@"; do
    args+=("${arg//PR_DIR/$PR_DIR}")
  done
  DATA_CODE=0
  STUB_GH_DIR="$stub" bash "$script" "${args[@]}" > "$tmp/data.out" 2> "$tmp/data.err" < /dev/null || DATA_CODE=$?
  return 0
}

# run_plain <script> <arguments...>: runs a script that needs no fake gh (in $PLAIN_DIR when set); same result files as run_data
run_plain() {
  local file=$1
  shift
  DATA_CODE=0
  (cd "${PLAIN_DIR:-.}" && bash "$file" "$@") > "$tmp/data.out" 2> "$tmp/data.err" < /dev/null || DATA_CODE=$?
  return 0
}

# run_stub <stub-dir> <script> <arguments...>: runs a script with the fake gh and the arguments as given; same result files as run_data
run_stub() {
  local stub=$1 file=$2
  shift 2
  DATA_CODE=0
  STUB_GH_DIR="$stub" bash "$file" "$@" > "$tmp/data.out" 2> "$tmp/data.err" < /dev/null || DATA_CODE=$?
  return 0
}

# expect_call <name> <stub-dir> <text>: the fake gh was called with this text (fixed string)
expect_call() {
  local name=$1 stub=$2 text=$3
  if grep -qF -- "$text" "$stub/calls.log"; then
    report "$name" ok
  else
    report "$name" fail "want: $text"$'\n'"log:  $(cat "$stub/calls.log")"
  fi
  return 0
}

# expect_no_call <name> <stub-dir> <text>: no call contains this text
expect_no_call() {
  local name=$1 stub=$2 text=$3
  if grep -qF -- "$text" "$stub/calls.log"; then
    report "$name" fail "unexpected: $text"$'\n'"log:  $(cat "$stub/calls.log")"
  else
    report "$name" ok
  fi
  return 0
}

# expect_error <name> <exit-code> <error> <retryable>: the last run_data call failed with one JSON line and nothing on stdout
expect_error() {
  local name=$1 want=$2 error=$3 retryable=$4 lines
  lines=$(wc -l < "$tmp/data.err" | tr -d ' ')
  if [[ $DATA_CODE -eq $want && ! -s "$tmp/data.out" && $lines -eq 1 ]] &&
    jq -e --arg e "$error" --argjson x "$want" --argjson r "$retryable" \
      '.error == $e and .exit == $x and .retryable == $r and (.message | length > 0)' "$tmp/data.err" > /dev/null; then
    report "$name" ok
  else
    report "$name" fail "exit $DATA_CODE (want $want); stdout: $(cat "$tmp/data.out"); stderr: $(cat "$tmp/data.err")"
  fi
  return 0
}

# expect_error_message <name> <text>: the message of the last error line contains the text
expect_error_message() {
  local name=$1 text=$2
  if jq -e --arg t "$text" '.message | contains($t)' "$tmp/data.err" > /dev/null 2>&1; then
    report "$name" ok
  else
    report "$name" fail "stderr: $(cat "$tmp/data.err")"
  fi
  return 0
}

# expect_error_text <name> <exit-code> <error> <retryable> <text>: expect_error and expect_error_message in one test
expect_error_text() {
  local name=$1 want=$2 error=$3 retryable=$4 text=$5 lines
  lines=$(wc -l < "$tmp/data.err" | tr -d ' ')
  if [[ $DATA_CODE -eq $want && ! -s "$tmp/data.out" && $lines -eq 1 ]] &&
    jq -e --arg e "$error" --argjson x "$want" --argjson r "$retryable" --arg t "$text" \
      '.error == $e and .exit == $x and .retryable == $r and (.message | contains($t))' "$tmp/data.err" > /dev/null; then
    report "$name" ok
  else
    report "$name" fail "exit $DATA_CODE (want $want), message part (want: $text); stdout: $(cat "$tmp/data.out"); stderr: $(cat "$tmp/data.err")"
  fi
  return 0
}

# expect_error_empty <name> <exit-code> <error> <retryable> <dir>: expect_error and expect_empty in one test
expect_error_empty() {
  local name=$1 want=$2 error=$3 retryable=$4 dir=$5 lines left
  lines=$(wc -l < "$tmp/data.err" | tr -d ' ')
  left=$(ls -A "$dir" | grep -v '^preflight\.json$' || true)
  if [[ $DATA_CODE -eq $want && ! -s "$tmp/data.out" && $lines -eq 1 && -z $left ]] &&
    jq -e --arg e "$error" --argjson x "$want" --argjson r "$retryable" \
      '.error == $e and .exit == $x and .retryable == $r and (.message | length > 0)' "$tmp/data.err" > /dev/null; then
    report "$name" ok
  else
    report "$name" fail "exit $DATA_CODE (want $want); files left: $left; stdout: $(cat "$tmp/data.out"); stderr: $(cat "$tmp/data.err")"
  fi
  return 0
}

# pr_variant <name> <jq-edit-of-the-base-pr> <jq-check-on-pr.json>
pr_variant() {
  local name=$1 edit=$2 expr=$3 stub
  stub=$(new_stub)
  jq "$edit" "$fixtures/gh/pr-base.json" > "$stub/pr-view.out"
  cp "$fixtures/gh/pulls.json" "$stub/api-pulls.out"
  run_data "$stub" pr 7 PR_DIR
  if [[ $DATA_CODE -eq 0 ]] && jq -e "$expr" "$PR_DIR/pr.json" > /dev/null; then
    report "pr/$name" ok
  else
    report "pr/$name" fail "exit $DATA_CODE: $(cat "$tmp/data.err")"
  fi
  return 0
}

# ---- PR body parser ----

for f in "$fixtures"/body/*.txt; do
  name=$(basename "$f" .txt)
  jq -Rs -f "$parser" "$f" > "$tmp/actual.json" 2> "$tmp/err" || cat "$tmp/err"
  check "body/$name" "$tmp/actual.json" "${f%.txt}.json"
done

# CRLF is generated, not stored: git and prettier would normalize a stored copy
awk '{printf "%s\r\n", $0}' "$fixtures/body/full-valid.txt" > "$tmp/crlf.txt"
jq -Rs -f "$parser" "$tmp/crlf.txt" > "$tmp/actual.json" 2> "$tmp/err" || cat "$tmp/err"
check "body/full-valid (CRLF)" "$tmp/actual.json" "$fixtures/body/full-valid.json"

# the skeleton in references/pr-body.md is a body the parser reads, with all six sections in it
body_contract="$root/plugins/dotclaude-dev/references/pr-body.md"
awk '/^## Skeleton/ {on = 1; next} on && /^```markdown/ {grab = 1; next} grab && /^```/ {exit} grab {print}' "$body_contract" |
  sed 's/<number>/1/g' > "$tmp/skeleton.txt"
jq -Rs -f "$parser" "$tmp/skeleton.txt" > "$tmp/actual.json" 2> "$tmp/err" || cat "$tmp/err"
if [[ $(grep -c '^## ' "$tmp/skeleton.txt") -eq 6 ]] &&
  jq -e '.fileRisk.state == "ok" and (.fileRisk.Critical | length) == 1 and (.fileRisk.Medium | length) == 0 and (.fileRisk.Low | length) == 2
    and .mergeDanger != null and .closes == {state: "ok", numbers: [1]}' "$tmp/actual.json" > /dev/null; then
  report "body/skeleton in pr-body.md is a valid body" ok
else
  report "body/skeleton in pr-body.md is a valid body" fail "skeleton: $(cat "$tmp/skeleton.txt") parsed: $(cat "$tmp/actual.json")"
fi

# ---- worktree state ----
# The fixtures are real `git worktree list --porcelain` output with the paths shortened and the commit ids replaced by readable names,
# except the prunable entry, which is hand-written

wt_count=$(jq length "$fixtures/worktree/cases.json")
i=0
while [[ $i -lt $wt_count ]]; do
  wt_fixture=$(jq -r ".[$i].fixture" "$fixtures/worktree/cases.json")
  wt_n=$(jq -r ".[$i].n" "$fixtures/worktree/cases.json")
  jq ".[$i].expected" "$fixtures/worktree/cases.json" > "$tmp/wt-expected.json"
  jq -Rs --arg n "$wt_n" -f "$root/plugins/dotclaude-dev/scripts/worktree-state.jq" "$fixtures/worktree/$wt_fixture" > "$tmp/wt-actual.json" 2> "$tmp/err" || cat "$tmp/err"
  check "worktree/$(jq -r ".[$i].name" "$fixtures/worktree/cases.json")" "$tmp/wt-actual.json" "$tmp/wt-expected.json"
  i=$((i + 1))
done

printf '' > "$tmp/empty.txt"
jq -Rs --arg n 7 -f "$root/plugins/dotclaude-dev/scripts/worktree-state.jq" "$tmp/empty.txt" > "$tmp/wt-actual.json" 2> "$tmp/err" || cat "$tmp/err"
printf '%s\n' '{"resumed":false,"prune":false,"path":null,"previousHead":null}' > "$tmp/wt-expected.json"
check "worktree/empty input" "$tmp/wt-actual.json" "$tmp/wt-expected.json"

# ---- pr-data.sh: pr and refs ----

stub=$(new_stub)
cp "$fixtures/gh/pr-base.json" "$stub/pr-view.out"
cp "$fixtures/gh/pulls.json" "$stub/api-pulls.out"
run_data "$stub" pr 7 PR_DIR
check "pr/pr.json" "$PR_DIR/pr.json" "$fixtures/gh/pr-ok.json"
jq 'del(.body, .files, .comments, .reviews, .statusCheckRollup)' "$fixtures/gh/pr-ok.json" > "$tmp/expected-stdout.json"
check "pr/stdout leaves out the bulky fields" "$tmp/data.out" "$tmp/expected-stdout.json"
expect_text "pr/body.txt" "$PR_DIR/body.txt" "$(jq -r '.body' "$fixtures/gh/pr-base.json")"

pr_variant "sameRepo is false for another repository" '.url = "https://github.example.local/x/y/pull/7"' '.sameRepo == false'
pr_variant "sameRepo ignores letter case" '.url = "https://github.example.local/O/R/pull/7"' '.sameRepo == true'
pr_variant "isDeployment is true for the deployment label" '.labels = [{"name": "type: deployment"}]' '.isDeployment == true'
pr_variant "isDeployment is false without labels" '.labels = []' '.isDeployment == false'
pr_variant "base commit comes from the REST answer" '.' '.baseRefOid == "base123"'

# a PR URL of another repository: the base commit is read from that repository, not from --repo
stub=$(new_stub)
jq '.url = "https://github.example.local/x/y/pull/7"' "$fixtures/gh/pr-base.json" > "$stub/pr-view.out"
cp "$fixtures/gh/pulls.json" "$stub/api-pulls.out"
run_data "$stub" pr 7 PR_DIR
if grep -q 'repos/x/y/pulls/7' "$stub/calls.log"; then
  report "pr/base commit is read from the repository of the PR URL" ok
else
  report "pr/base commit is read from the repository of the PR URL" fail "$(cat "$stub/calls.log")"
fi

stub=$(new_stub)
jq '.body = null' "$fixtures/gh/pr-base.json" > "$stub/pr-view.out"
cp "$fixtures/gh/pulls.json" "$stub/api-pulls.out"
run_data "$stub" pr 7 PR_DIR
expect_text "pr/null body gives an empty body.txt" "$PR_DIR/body.txt" ""

# ---- pr-data.sh: issue, ci, feedback ----

stub=$(new_stub)
printf '%s\n' '{"number":12,"title":"Sample","state":"OPEN","body":"b","labels":[]}' > "$stub/issue-view.out"
run_data "$stub" issue 12 PR_DIR
expect_text "issue/stdout" "$tmp/data.out" "#12 Sample (OPEN)"
check "issue/issue-12.json" "$PR_DIR/issue-12.json" "$stub/issue-view.out"

# alert: the reduced file and the printed line
stub=$(new_stub)
cp "$fixtures/gh/alert-open.json" "$stub/api-alerts.out"
run_data "$stub" alert 3 PR_DIR
expect_text "alert/stdout" "$tmp/data.out" "#3 js/sql-injection (open)"
check "alert/alert-3.json is the reduced object" "$PR_DIR/alert-3.json" "$fixtures/gh/alert-expected.json"
expect_call "alert/asks the code scanning API of the repository" "$stub" "api --hostname github.example.local repos/o/r/code-scanning/alerts/3"

for st_n in fixed:4 dismissed:5; do
  st=${st_n%%:*}
  n=${st_n##*:}
  stub=$(new_stub)
  cp "$fixtures/gh/alert-$st.json" "$stub/api-alerts.out"
  run_data "$stub" alert "$n" PR_DIR
  expect_text "alert/state $st is printed" "$tmp/data.out" "#$n js/sql-injection ($st)"
done

stub=$(new_stub)
jq '.state = "auto_dismissed"' "$fixtures/gh/alert-open.json" > "$stub/api-alerts.out"
run_data "$stub" alert 3 PR_DIR
expect_text "alert/an unexpected state passes through" "$tmp/data.out" "#3 js/sql-injection (auto_dismissed)"

stub=$(new_stub)
cp "$fixtures/gh/alert-no-severity.json" "$stub/api-alerts.out"
run_data "$stub" alert 3 PR_DIR
if jq -e '.severity == null and .ruleId == "js/unused-local"' "$PR_DIR/alert-3.json" > /dev/null 2>&1; then
  report "alert/no severity stays null" ok
else
  report "alert/no severity stays null" fail "$(cat "$PR_DIR/alert-3.json" 2> /dev/null)"
fi

stub=$(new_stub)
cp "$fixtures/gh/alert-no-instance.json" "$stub/api-alerts.out"
run_data "$stub" alert 3 PR_DIR
if jq -e '.message == null and .path == null' "$PR_DIR/alert-3.json" > /dev/null 2>&1; then
  report "alert/no instance gives null message and path" ok
else
  report "alert/no instance gives null message and path" fail "$(cat "$PR_DIR/alert-3.json" 2> /dev/null)"
fi
expect_text "alert/no instance still prints the line" "$tmp/data.out" "#3 js/sql-injection (open)"

stub=$(new_stub)
jq '.most_recent_instance.message.text = "quote \" backslash \\ and\nnew line"' "$fixtures/gh/alert-open.json" > "$stub/api-alerts.out"
run_data "$stub" alert 3 PR_DIR
if jq -e '.message == "quote \" backslash \\ and\nnew line"' "$PR_DIR/alert-3.json" > /dev/null 2>&1; then
  report "alert/a message with quotes, backslash and newline stays intact" ok
else
  report "alert/a message with quotes, backslash and newline stays intact" fail "$(cat "$PR_DIR/alert-3.json" 2> /dev/null)"
fi

stub=$(new_stub)
fail_stub "$stub" api-alerts 1 "gh: Not Found (HTTP 404)" '{"message":"Not Found"}'
run_data "$stub" alert 9 PR_DIR
expect_error_empty "alert/not found" 11 not_found false "$PR_DIR"

stub=$(new_stub)
fail_stub "$stub" api-alerts 1 "Advanced Security must be enabled for this repository to use code scanning. (HTTP 403)" '{"message":"Advanced Security must be enabled"}'
run_data "$stub" alert 3 PR_DIR
expect_error_empty "alert/code scanning not enabled is not_found, no body on stdout" 11 not_found false "$PR_DIR"

stub=$(new_stub)
printf '%s\n' 'not json' > "$stub/api-alerts.out"
run_data "$stub" alert 3 PR_DIR
expect_error_empty "alert/unreadable response" 1 other false "$PR_DIR"

for body in 'null' '{"most_recent_instance":null}' '{"number":"x"}' ''; do
  stub=$(new_stub)
  printf '%s' "$body" > "$stub/api-alerts.out"
  run_data "$stub" alert 3 PR_DIR
  expect_error_empty "alert/a response that is not an alert is an error: ${body:-empty}" 1 other false "$PR_DIR"
done

run_data "$stub" alert abc PR_DIR
expect_error "usage/alert number is not a number" 2 usage false
run_data "$stub" alert 3
expect_error "usage/alert without a folder" 2 usage false

# ci works offline on the pr.json that pr wrote
count=$(jq length "$fixtures/gh/ci-cases.json")
i=0
while [[ $i -lt $count ]]; do
  stub=$(new_stub)
  jq ".[$i].in" "$fixtures/gh/ci-cases.json" > "$tmp/ci-in.json"
  jq ".[$i].expected" "$fixtures/gh/ci-cases.json" > "$tmp/ci-expected.json"
  SEED_PR_JSON="$tmp/ci-in.json"
  run_data "$stub" ci PR_DIR
  SEED_PR_JSON=""
  check "ci/$(jq -r ".[$i].name" "$fixtures/gh/ci-cases.json")" "$tmp/data.out" "$tmp/ci-expected.json"
  i=$((i + 1))
done

stub=$(new_stub)
cp "$fixtures/gh/feedback-inline-pages.txt" "$stub/api-comments.out"
SEED_PR_JSON="$fixtures/gh/feedback-view.json"
run_data "$stub" feedback 7 PR_DIR
SEED_PR_JSON=""
check "feedback/feedback.json" "$PR_DIR/feedback.json" "$fixtures/gh/feedback-expected.json"
expect_text "feedback/counts" "$tmp/data.out" "1 comments, 1 reviews, 2 inline comments"
if grep -q -- '--paginate' "$stub/calls.log"; then
  report "feedback/asks gh for all pages" ok
else
  report "feedback/asks gh for all pages" fail "$(cat "$stub/calls.log")"
fi

stub=$(new_stub)
printf '%s\n' '[]' > "$stub/api-comments.out"
printf '%s\n' '{"comments":[],"reviews":[]}' > "$tmp/no-comments.json"
SEED_PR_JSON="$tmp/no-comments.json"
run_data "$stub" feedback 7 PR_DIR
SEED_PR_JSON=""
expect_text "feedback/no comments at all" "$tmp/data.out" "0 comments, 0 reviews, 0 inline comments"

# ---- the fake gh itself ----

stub=$(new_stub)
STUB_GH_DIR="$stub" bash -c 'gh pr view 7' > "$tmp/data.out" 2> "$tmp/data.err"
DATA_CODE=$?
[[ $DATA_CODE -eq 97 ]] && grep -q 'lacks "--repo"' "$tmp/data.err" &&
  report "stub/a call without a required flag fails" ok ||
  report "stub/a call without a required flag fails" fail "exit $DATA_CODE: $(cat "$tmp/data.err")"

stub=$(new_stub)
echo default > "$stub/api.out"
echo reviewer1 > "$stub/api-user.out"
echo seven > "$stub/api-pulls.out"
echo discussion > "$stub/api-comments.out"
while IFS='|' read -r want_answer args; do
  # shellcheck disable=SC2086
  STUB_GH_DIR="$stub" bash -c "gh api $args" > "$tmp/data.out" 2> "$tmp/data.err"
  expect_text "stub/api answer for: $args" "$tmp/data.out" "$want_answer"
done << 'EOF'
reviewer1|user --hostname h --jq .login
seven|--hostname h repos/o/r/pulls/7
discussion|--paginate --hostname h repos/o/r/pulls/7/comments
default|--hostname h repos/o/r/code-scanning/alerts/3
EOF

# ---- error contract (contract.sh) ----
# Every error class, tested once through the pr subcommand of pr-data.sh; pr-create.sh gets the same code by sourcing the file.
# The stub also prints an error body on stdout, which must not leak.

while IFS='|' read -r label gh_exit stderr_text want_exit error retryable; do
  stub=$(new_stub)
  fail_stub "$stub" pr-view "$gh_exit" "$stderr_text" '{"message":"error body"}'
  run_data "$stub" pr 7 PR_DIR
  expect_error_empty "contract/$label" "$want_exit" "$error" "$retryable" "$PR_DIR"
done << 'EOF'
auth by gh exit code 4|4|authentication required|10|auth|false
auth by HTTP 401|1|gh: Bad credentials (HTTP 401)|10|auth|false
not found, GraphQL|1|GraphQL: Could not resolve to a PullRequest with the number of 9. (repository.pullRequest)|11|not_found|false
not found, HTTP 404|1|gh: Not Found (HTTP 404)|11|not_found|false
forbidden without rate limit|1|gh: Forbidden (HTTP 403)|11|not_found|false
rate limit|1|gh: API rate limit exceeded (HTTP 403)|12|rate_limited|true
network|1|error connecting to github.example.local|13|network|true
unknown error|1|something odd happened|1|other|false
auth by the gh auth login hint|1|To get started with GitHub CLI, please run: gh auth login|10|auth|false
not found, HTTP 410|1|gh: Gone (HTTP 410)|11|not_found|false
not found, no pull requests|1|no pull requests found for branch x|11|not_found|false
secondary rate limit|1|You have exceeded a secondary rate limit (HTTP 403)|12|rate_limited|true
rate limit by HTTP 429|1|gh: Too Many Requests (HTTP 429)|12|rate_limited|true
network, no such host|1|lookup github.example.local: no such host|13|network|true
network, dial tcp|1|dial tcp 10.0.0.1:443: i/o failure|13|network|true
network, timeout|1|request failed: timeout|13|network|true
network, connection refused|1|connection refused|13|network|true
network, could not resolve host|1|Could not resolve host: github.example.local|13|network|true
EOF

stub=$(new_stub)
fail_stub "$stub" pr-view 1 "something odd happened"
run_data "$stub" pr 7 PR_DIR
jq -e '.message | contains("something odd happened")' "$tmp/data.err" > /dev/null &&
  report "pr/unknown error shows the first line of gh" ok ||
  report "pr/unknown error shows the first line of gh" fail "$(cat "$tmp/data.err")"

# the PR was read, the base commit call fails: nothing is written
stub=$(new_stub)
cp "$fixtures/gh/pr-base.json" "$stub/pr-view.out"
fail_stub "$stub" api-pulls 1 "gh: Not Found (HTTP 404)" '{"message":"Not Found"}'
run_data "$stub" pr 7 PR_DIR
expect_error_empty "pr/base commit call fails" 11 not_found false "$PR_DIR"

stub=$(new_stub)
fail_stub "$stub" api-pulls 1 "error connecting to github.example.local"
cp "$fixtures/gh/pr-base.json" "$stub/pr-view.out"
run_data "$stub" pr 7 PR_DIR
expect_error "pr/network error on the base commit call" 13 network true

stub=$(new_stub)
fail_stub "$stub" issue-view 1 "GraphQL: Could not resolve to an Issue with the number of 9."
run_data "$stub" issue 9 PR_DIR
expect_error "issue/not found" 11 not_found false

# the offline subcommands need the pr.json that pr wrote
stub=$(new_stub)
run_data "$stub" ci PR_DIR
expect_error "ci/no pr.json" 1 other false
run_data "$stub" feedback 7 PR_DIR
expect_error "feedback/no pr.json" 1 other false

# The page fetch fails and jq on empty input would accept it: must still fail, with no feedback file
stub=$(new_stub)
fail_stub "$stub" api-comments 1 "gh: Not Found (HTTP 404)" '{"message":"Not Found"}'
SEED_PR_JSON="$fixtures/gh/feedback-view.json"
run_data "$stub" feedback 7 PR_DIR
SEED_PR_JSON=""
expect_error "feedback/page fetch fails" 11 not_found false
expect_absent "feedback/page fetch fails leaves no feedback.json" "$PR_DIR/feedback.json"

stub=$(new_stub)
run_data "$stub" pr 7
expect_error "usage/too few arguments" 2 usage false
for bad_pr_arg in --web '#42' abc '' 'feature/x' '-1'; do
  bad_stub=$(new_stub)
  run_data "$bad_stub" pr "$bad_pr_arg" PR_DIR
  expect_error "usage/pr argument '$bad_pr_arg' is neither a number nor a URL" 2 usage false
  [[ ! -f $bad_stub/calls.log ]] && report "usage/pr argument '$bad_pr_arg' never reaches gh" ok ||
    report "usage/pr argument '$bad_pr_arg' never reaches gh" fail "$(cat "$bad_stub/calls.log")"
done
# a number and a PR URL are the two accepted forms
for good_pr_arg in 7 https://github.example.local/o/r/pull/7; do
  good_stub=$(new_stub)
  cp "$fixtures/gh/pr-base.json" "$good_stub/pr-view.out"
  cp "$fixtures/gh/pulls.json" "$good_stub/api-pulls.out"
  run_data "$good_stub" pr "$good_pr_arg" PR_DIR
  [[ $DATA_CODE -eq 0 ]] && report "pr/argument '$good_pr_arg' is accepted" ok ||
    report "pr/argument '$good_pr_arg' is accepted" fail "exit $DATA_CODE: $(cat "$tmp/data.err")"
done
run_data "$stub" issue abc PR_DIR
expect_error "usage/issue number is not a number" 2 usage false
run_data "$stub" feedback abc PR_DIR
expect_error "usage/feedback number is not a number" 2 usage false
run_data "$stub" bogus
expect_error "usage/unknown subcommand" 2 usage false

# ---- remote-host.sh ----

host_script="$root/plugins/dotclaude-dev/scripts/remote-host.sh"
while IFS='|' read -r url want; do
  run_plain "$host_script" --url "$url"
  expect_text "remote-host/$url" "$tmp/data.out" "$want"
done << 'EOF'
https://github.example.local/org/repo.git|github.example.local
git@github.example.local:org/repo.git|github.example.local
ssh://git@github.example.local:2222/org/repo.git|github.example.local
https://user@github.example.local/org/repo|github.example.local
HTTPS://GitHub.com/o/r|GitHub.com
SSH://git@github.example.local:2222/o/r.git|github.example.local
EOF

run_plain "$host_script" --url "https:///x"
expect_error "remote-host/no host in the URL" 1 other false
run_plain "$host_script"
expect_error "remote-host/no arguments" 2 usage false

# a real remote of a scratch repository
scratch=$(mktemp -d "$tmp/repo-XXXXXX")
git init -q "$scratch"
git -C "$scratch" remote add origin git@github.example.local:o/r.git
PLAIN_DIR="$scratch" run_plain "$host_script" origin
expect_text "remote-host/URL and host of a remote" "$tmp/data.out" $'git@github.example.local:o/r.git\ngithub.example.local'
PLAIN_DIR="$scratch" run_plain "$host_script" nowhere
expect_error "remote-host/remote does not exist" 1 other false

# credentials in an http(s) URL never reach stdout or an error line; the user of an ssh URL is not a secret and stays
cred_repo=$(mktemp -d "$tmp/repo-XXXXXX")
git init -q "$cred_repo"
git -C "$cred_repo" remote add origin https://user:SECRET@github.example.local/o/r.git
PLAIN_DIR="$cred_repo" run_plain "$host_script" origin
expect_text "remote-host/user and password are dropped from the URL" "$tmp/data.out" $'https://github.example.local/o/r.git\ngithub.example.local'
git -C "$cred_repo" remote set-url origin https://SECRET@github.example.local/o/r.git
PLAIN_DIR="$cred_repo" run_plain "$host_script" origin
expect_text "remote-host/a token as the user is dropped from the URL" "$tmp/data.out" $'https://github.example.local/o/r.git\ngithub.example.local'
git -C "$cred_repo" remote set-url origin ssh://git@github.example.local:2222/o/r.git
PLAIN_DIR="$cred_repo" run_plain "$host_script" origin
expect_text "remote-host/the user of an ssh URL stays" "$tmp/data.out" $'ssh://git@github.example.local:2222/o/r.git\ngithub.example.local'
git -C "$cred_repo" remote set-url origin HTTPS://user:SECRET@GitHub.com/o/r.git
PLAIN_DIR="$cred_repo" run_plain "$host_script" origin
expect_text "remote-host/the password is dropped from an upper-case scheme too" "$tmp/data.out" $'HTTPS://GitHub.com/o/r.git\nGitHub.com'
run_plain "$host_script" --url "https://user:SECRET@/x"
if [[ $DATA_CODE -eq 1 ]] && ! grep -q SECRET "$tmp/data.err"; then
  report "remote-host/the error for a URL without host does not show the password" ok
else
  report "remote-host/the error for a URL without host does not show the password" fail "exit $DATA_CODE: $(cat "$tmp/data.err")"
fi

# ---- pr-create.sh ----

create_script="$root/plugins/dotclaude-dev/scripts/pr-create.sh"
repo_url=https://github.example.local/o/r

stub=$(new_stub)
printf '%s\n' '[{"name":"type: bug","description":"Bug"},{"name":"aspect: ui","description":"UI"},{"name":"priority: high","description":"x"}]' > "$stub/label-list.out"
work=$(new_work)
run_stub "$stub" "$create_script" labels "$work"
printf '%s\n' '{"mode":"taxonomy","labels":[{"name":"type: bug","description":"Bug"},{"name":"aspect: ui","description":"UI"}]}' > "$tmp/create-expected.json"
check "labels/taxonomy mode keeps type: and aspect: labels" "$tmp/data.out" "$tmp/create-expected.json"
jq '.labels' "$tmp/data.out" > "$tmp/create-expected.json"
check "labels/labels.json holds only the labels that may be chosen (type: and aspect:), not priority:" "$work/labels.json" "$tmp/create-expected.json"
expect_call "labels/limit and repository are passed" "$stub" "label list --repo $repo_url --json name,description --limit 50"

stub=$(new_stub)
printf '%s\n' '[{"name":"bug","description":"b"},{"name":"help wanted","description":""}]' > "$stub/label-list.out"
work=$(new_work)
run_stub "$stub" "$create_script" labels "$work"
jq -c '{mode: "fallback", labels: .}' "$stub/label-list.out" > "$tmp/create-expected.json"
check "labels/fallback mode without type: or aspect: labels" "$tmp/data.out" "$tmp/create-expected.json"
check "labels/fallback mode: labels.json holds all labels" "$work/labels.json" "$stub/label-list.out"

# list-open-prs: the head is the branch name on the remote (preflight.json), PRs from forks with the same head name do not count
stub=$(new_stub)
printf '%s\n' '[]' > "$stub/pr-list.out"
work=$(new_work)
jq '. + {remoteBranch: "fix/x-new"}' "$work/preflight.json" > "$work/preflight.new" && mv "$work/preflight.new" "$work/preflight.json"
run_stub "$stub" "$create_script" list-open-prs "$work"
expect_text "list-open-prs/none" "$tmp/data.out" "[]"
expect_call "list-open-prs/asks for the remote branch and open PRs" "$stub" "pr list --repo $repo_url --head fix/x-new --state open"

stub=$(new_stub)
printf '%s\n' '[{"number":5,"title":"mine","url":"https://github.example.local/o/r/pull/5","isCrossRepository":false},{"number":6,"title":"from a fork","url":"https://github.example.local/o/r/pull/6","isCrossRepository":true}]' > "$stub/pr-list.out"
run_stub "$stub" "$create_script" list-open-prs "$work"
expect_text "list-open-prs/a PR from a fork with the same head name is ignored, url is kept" "$tmp/data.out" '[{"number":5,"title":"mine","url":"https://github.example.local/o/r/pull/5"}]'

work=$(new_work)
run_stub "$stub" "$create_script" list-open-prs "$work"
expect_error_text "list-open-prs/preflight.json without remoteBranch" 1 other false "preflight.sh create-pr"

# create: title and body come from files and reach gh unchanged
title='fix: quote `$TMPDIR` in "paths" $(echo x)'
stub=$(new_stub)
printf '%s\n' 'https://github.example.local/o/r/pull/9' > "$stub/pr-create.out"
work=$(new_work)
printf '%s\n' "$title" > "$work/title.txt"
printf '%s\n' 'body text' > "$work/body.txt"
run_stub "$stub" "$create_script" create "$work" no "type: bug" "aspect: ui"
expect_text "create/stdout is only the URL" "$tmp/data.out" "https://github.example.local/o/r/pull/9"
expect_call "create/repository, assignee, title and body file" "$stub" "pr create --repo $repo_url --assignee @me --title $title --body-file $work/body.txt"
expect_call "create/several labels" "$stub" "--label type: bug --label aspect: ui"
expect_no_call "create/no draft flag for no" "$stub" "--draft"

stub=$(new_stub)
run_stub "$stub" "$create_script" create "$work" yes "type: bug"
expect_call "create/draft with one label" "$stub" "--body-file $work/body.txt --draft --label type: bug"
stub=$(new_stub)
run_stub "$stub" "$create_script" create "$work" no
expect_no_call "create/no label flag without labels" "$stub" "--label"

stub=$(new_stub)
fail_stub "$stub" pr-create 1 "error connecting to github.example.local"
run_stub "$stub" "$create_script" create "$work" no
expect_error "create/gh fails" 13 network false
jq -e '.message | startswith("Could not create the PR")' "$tmp/data.err" > /dev/null &&
  report "create/failure message says create" ok ||
  report "create/failure message says create" fail "$(cat "$tmp/data.err")"
expect_error_message "create/network error says to look for the PR before re-running" "gh pr list --head"

# a network error after the server accepted the request could have created the PR: never retryable (timeout, dial tcp)
for phrase in "Post \"https://github.example.local/api/graphql\": context deadline exceeded (Client.Timeout exceeded while awaiting headers) timeout" "dial tcp 10.0.0.1:443: i/o timeout"; do
  stub=$(new_stub)
  fail_stub "$stub" pr-create 1 "$phrase"
  run_stub "$stub" "$create_script" create "$work" no
  expect_error "create/$phrase" 13 network false
done

# a missing label is not a wrong PR number
stub=$(new_stub)
fail_stub "$stub" pr-create 1 "could not add label: 'nope' not found"
run_stub "$stub" "$create_script" create "$work" no "nope"
expect_error_text "create/label does not exist" 11 not_found false "Check the labels"

stub=$(new_stub)
work=$(new_work)
printf '%s\n' 'body text' > "$work/body.txt"
run_stub "$stub" "$create_script" create "$work" no
expect_error "create/title file missing" 1 other false
printf '%s\n' '' > "$work/title.txt"
run_stub "$stub" "$create_script" create "$work" no
expect_error "create/empty title" 1 other false
work=$(new_work)
printf '%s\n' 'a title' > "$work/title.txt"
run_stub "$stub" "$create_script" create "$work" no
expect_error "create/body file missing" 1 other false

run_stub "$stub" "$create_script" create "$work" maybe
expect_error "usage/create draft is not yes or no" 2 usage false
run_stub "$stub" "$create_script" bogus
expect_error "usage/pr-create unknown subcommand" 2 usage false
run_stub "$stub" "$create_script" repo github.example.local git@github.example.local:o/r.git
expect_error "usage/pr-create repo is gone, preflight.sh reads the repository" 2 usage false

# every gh subcommand reads host and repository from preflight.json: without the file it stops before any gh call
stub=$(new_stub)
while IFS= read -r args; do
  NO_PREFLIGHT=1 run_data "$stub" $args
  expect_error_text "preflight.json/pr-data $args needs the file" 1 other false "Run preflight first"
done << 'EOT'
pr 7 PR_DIR
issue 7 PR_DIR
alert 7 PR_DIR
feedback 7 PR_DIR
EOT
work=$(mktemp -d "$tmp/work-XXXXXX")
printf '%s\n' 'a title' > "$work/title.txt"
printf '%s\n' 'body text' > "$work/body.txt"
for sub in "labels $work" "list-open-prs $work" "create $work no"; do
  run_stub "$stub" "$create_script" $sub
  expect_error_text "preflight.json/pr-create ${sub%% *} needs the file" 1 other false "Run preflight first"
done
[[ ! -e $stub/calls.log ]] &&
  report "preflight.json/no gh call without the file" ok ||
  report "preflight.json/no gh call without the file" fail "$(cat "$stub/calls.log")"

# host and repository come from the file, not from anywhere else
stub=$(new_stub)
work=$(mktemp -d "$tmp/work-XXXXXX")
printf '%s\n' '{"host":"other.example.org","repoUrl":"https://other.example.org/x/y","repoPath":"x/y"}' > "$work/preflight.json"
cp "$fixtures/gh/alert-open.json" "$stub/api-alerts.out"
run_stub "$stub" "$script" alert 3 "$work"
expect_call "preflight.json/alert uses the host from the file" "$stub" "--hostname other.example.org"
expect_call "preflight.json/alert uses the repository path from the file" "$stub" "repos/x/y/code-scanning/alerts/3"
printf '%s\n' '[]' > "$stub/label-list.out"
run_stub "$stub" "$create_script" labels "$work"
expect_call "preflight.json/labels uses the repository URL from the file" "$stub" "label list --repo https://other.example.org/x/y"

# ---- branch-diff.sh ----
# Each case builds a small scratch repository; origin/main is a plain ref, no real remote is involved.

diff_script="$root/plugins/dotclaude-dev/scripts/branch-diff.sh"

# make_branch_repo <dir>: a repository with one commit on main, refs/remotes/origin/main at that commit, HEAD on branch feature
make_branch_repo() {
  local dir=$1
  git init -q "$dir"
  git -C "$dir" symbolic-ref HEAD refs/heads/main
  git -C "$dir" config user.name tester
  git -C "$dir" config user.email tester@example.com
  printf 'one\n' > "$dir/base.txt"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m base
  git -C "$dir" update-ref refs/remotes/origin/main HEAD
  git -C "$dir" checkout -q -b feature
  return 0
}

# commit_all <dir>
commit_all() {
  local dir=$1
  git -C "$dir" add -A
  git -C "$dir" commit -q -m change
  return 0
}

# expect_jq <name> <jq-filter> [jq-options...]: the last run succeeded and the filter is true on its stdout
expect_jq() {
  local name=$1 filter=$2
  shift 2
  if [[ $DATA_CODE -eq 0 ]] && jq -e "$@" "$filter" "$tmp/data.out" > /dev/null 2>&1; then
    report "$name" ok
  else
    report "$name" fail "exit $DATA_CODE; stdout: $(cat "$tmp/data.out"); stderr: $(cat "$tmp/data.err")"
  fi
  return 0
}

# expect_in_file <name> <file> <text>: the file contains the text (fixed string)
expect_in_file() {
  local name=$1 file=$2 text=$3
  if grep -qF -- "$text" "$file" 2> /dev/null; then
    report "$name" ok
  else
    report "$name" fail "not found: $text in $file"
  fi
  return 0
}

bd_repo=$(mktemp -d "$tmp/bd-XXXXXX")
make_branch_repo "$bd_repo"
mkdir -p "$bd_repo/src"
printf 'a1\na2\n' > "$bd_repo/src/a.txt"
printf 'one\ntwo\n' > "$bd_repo/base.txt"
commit_all "$bd_repo"

bd_dir=$(mktemp -d "$tmp/folder-XXXXXX")
PLAIN_DIR="$bd_repo" run_plain "$diff_script" files origin main "$bd_dir"
expect_jq "branch-diff/files: hand-written files, numbers and diff files" \
  '. == [{path: "base.txt", renamedFrom: null, added: 1, removed: 0, generated: false, diff: ($d + "/diff/001.diff")},
         {path: "src/a.txt", renamedFrom: null, added: 2, removed: 0, generated: false, diff: ($d + "/diff/002.diff")}]' --arg d "$bd_dir"
expect_in_file "branch-diff/files: diff file holds the change" "$bd_dir/diff/001.diff" "+two"
check "branch-diff/files: file-table.json holds the printed table" "$bd_dir/file-table.json" "$tmp/data.out"

# one call per folder: a second call must not mix its files with the first run's
PLAIN_DIR="$bd_repo" run_plain "$diff_script" files origin main "$bd_dir"
expect_error_text "branch-diff/files: a second call in the same folder is refused" 1 other false "already has diff/"
expect_in_file "branch-diff/files: the refusal leaves the first run's diff file alone" "$bd_dir/diff/001.diff" "+two"

bd_dir=$(mktemp -d "$tmp/folder-XXXXXX")
PLAIN_DIR="$bd_repo/src" run_plain "$diff_script" files origin main "$bd_dir"
expect_jq "branch-diff/files: from a subdirectory of the repository" \
  '[.[] | {path, added, removed}] == [{path: "base.txt", added: 1, removed: 0}, {path: "src/a.txt", added: 2, removed: 0}]'
expect_in_file "branch-diff/files: subdirectory run writes the diff" "$bd_dir/diff/002.diff" "+a2"

bd_odd=$(mktemp -d "$tmp/bd-XXXXXX")
make_branch_repo "$bd_odd"
for name in "a b.txt" 'q"d.txt' "-dash.txt" $'n\nl.txt'; do
  printf 'x\n' > "$bd_odd/$name"
done
commit_all "$bd_odd"
bd_dir=$(mktemp -d "$tmp/folder-XXXXXX")
PLAIN_DIR="$bd_odd" run_plain "$diff_script" files origin main "$bd_dir"
expect_jq "branch-diff/files: awkward file names arrive unchanged" \
  '([.[].path] | sort) == ["-dash.txt", "a b.txt", "n\nl.txt", "q\"d.txt"] and all(.[]; .diff != null and .added == 1)'
count=$(ls "$bd_dir/diff" | wc -l | tr -d ' ')
if [[ $count -eq 4 ]]; then report "branch-diff/files: awkward names each get a diff file" ok; else report "branch-diff/files: awkward names each get a diff file" fail "$count files"; fi

bd_none=$(mktemp -d "$tmp/bd-XXXXXX")
make_branch_repo "$bd_none"
bd_dir=$(mktemp -d "$tmp/folder-XXXXXX")
PLAIN_DIR="$bd_none" run_plain "$diff_script" files origin main "$bd_dir"
expect_jq "branch-diff/files: no change prints an empty table" '. == []'
expect_empty "branch-diff/files: no change writes no diff file" "$bd_dir/diff"

bd_bin=$(mktemp -d "$tmp/bd-XXXXXX")
make_branch_repo "$bd_bin"
printf 'a\0b\n' > "$bd_bin/pic.dat"
commit_all "$bd_bin"
bd_dir=$(mktemp -d "$tmp/folder-XXXXXX")
PLAIN_DIR="$bd_bin" run_plain "$diff_script" files origin main "$bd_dir"
expect_jq "branch-diff/files: binary file has null counts and a diff file" \
  '. == [{path: "pic.dat", renamedFrom: null, added: null, removed: null, generated: false, diff: ($d + "/diff/001.diff")}]' --arg d "$bd_dir"
expect_in_file "branch-diff/files: binary diff file says so" "$bd_dir/diff/001.diff" "Binary files"

PLAIN_DIR="$bd_repo" run_plain "$diff_script" file origin main base.txt
expect_in_file "branch-diff/file: prints the diff of one path" "$tmp/data.out" "+two"
PLAIN_DIR="$bd_repo" run_plain "$diff_script" file origin main nothing.txt
if [[ $DATA_CODE -eq 0 && ! -s "$tmp/data.out" ]]; then report "branch-diff/file: a path without change prints nothing" ok; else report "branch-diff/file: a path without change prints nothing" fail "exit $DATA_CODE: $(cat "$tmp/data.out")"; fi

bd_glob=$(mktemp -d "$tmp/bd-XXXXXX")
make_branch_repo "$bd_glob"
printf 'x\n' > "$bd_glob/*.txt"
printf 'y\n' > "$bd_glob/other.txt"
commit_all "$bd_glob"
PLAIN_DIR="$bd_glob" run_plain "$diff_script" file origin main '*.txt'
expect_in_file "branch-diff/file: a glob character matches only itself" "$tmp/data.out" "+x"
if grep -qF "other.txt" "$tmp/data.out"; then report "branch-diff/file: glob does not match other files" fail "other.txt in output"; else report "branch-diff/file: glob does not match other files" ok; fi

# generated files: numbers only, no diff file, no number consumed
bd_gen=$(mktemp -d "$tmp/bd-XXXXXX")
make_branch_repo "$bd_gen"
mkdir -p "$bd_gen/apps/web" "$bd_gen/src"
printf '{}\n' > "$bd_gen/package-lock.json"
printf 'lock\n' > "$bd_gen/apps/web/yarn.lock"
printf 'lock\n' > "$bd_gen/pnpm-lock.yaml"
printf 'x\n' > "$bd_gen/src/x.txt"
commit_all "$bd_gen"
bd_dir=$(mktemp -d "$tmp/folder-XXXXXX")
PLAIN_DIR="$bd_gen" run_plain "$diff_script" files origin main "$bd_dir"
expect_jq "branch-diff/generated: lockfiles are numbers only" \
  '. == [{path: "apps/web/yarn.lock", renamedFrom: null, added: 1, removed: 0, generated: true, diff: null},
         {path: "package-lock.json", renamedFrom: null, added: 1, removed: 0, generated: true, diff: null},
         {path: "pnpm-lock.yaml", renamedFrom: null, added: 1, removed: 0, generated: true, diff: null},
         {path: "src/x.txt", renamedFrom: null, added: 1, removed: 0, generated: false, diff: ($d + "/diff/001.diff")}]' --arg d "$bd_dir"
count=$(ls "$bd_dir/diff" | wc -l | tr -d ' ')
if [[ $count -eq 1 ]]; then report "branch-diff/generated: only the hand-written file gets a diff file" ok; else report "branch-diff/generated: only the hand-written file gets a diff file" fail "$count files"; fi
PLAIN_DIR="$bd_gen" run_plain "$diff_script" file origin main package-lock.json
expect_in_file "branch-diff/file: a generated file's diff on demand" "$tmp/data.out" "+{}"

bd_attr=$(mktemp -d "$tmp/bd-XXXXXX")
make_branch_repo "$bd_attr"
mkdir -p "$bd_attr/gen"
printf 'gen/* linguist-generated\n' > "$bd_attr/.gitattributes"
printf 'x\n' > "$bd_attr/gen/out.js"
commit_all "$bd_attr"
bd_dir=$(mktemp -d "$tmp/folder-XXXXXX")
PLAIN_DIR="$bd_attr" run_plain "$diff_script" files origin main "$bd_dir"
expect_jq "branch-diff/generated: attribute marks a file, .gitattributes itself is hand-written" \
  '[.[] | {path, generated}] == [{path: ".gitattributes", generated: false}, {path: "gen/out.js", generated: true}]'

bd_beat=$(mktemp -d "$tmp/bd-XXXXXX")
make_branch_repo "$bd_beat"
printf 'package-lock.json -linguist-generated\n' > "$bd_beat/.gitattributes"
printf '{}\n' > "$bd_beat/package-lock.json"
commit_all "$bd_beat"
bd_dir=$(mktemp -d "$tmp/folder-XXXXXX")
PLAIN_DIR="$bd_beat" run_plain "$diff_script" files origin main "$bd_dir"
expect_jq "branch-diff/generated: an explicit attribute beats the lockfile list" \
  '[.[] | {path, generated}] == [{path: ".gitattributes", generated: false}, {path: "package-lock.json", generated: false}] and all(.[]; .diff != null)'

bd_del=$(mktemp -d "$tmp/bd-XXXXXX")
make_branch_repo "$bd_del"
printf 'lock\n' > "$bd_del/yarn.lock"
commit_all "$bd_del"
git -C "$bd_del" update-ref refs/remotes/origin/main HEAD
git -C "$bd_del" rm -q yarn.lock
commit_all "$bd_del"
bd_dir=$(mktemp -d "$tmp/folder-XXXXXX")
PLAIN_DIR="$bd_del" run_plain "$diff_script" files origin main "$bd_dir"
expect_jq "branch-diff/generated: a deleted lockfile is still generated" \
  '. == [{path: "yarn.lock", renamedFrom: null, added: 0, removed: 1, generated: true, diff: null}]'

bd_lockbinary=$(mktemp -d "$tmp/bd-XXXXXX")
make_branch_repo "$bd_lockbinary"
printf 'a\0b\n' > "$bd_lockbinary/package-lock.json"
commit_all "$bd_lockbinary"
bd_dir=$(mktemp -d "$tmp/folder-XXXXXX")
PLAIN_DIR="$bd_lockbinary" run_plain "$diff_script" files origin main "$bd_dir"
expect_jq "branch-diff/generated: a binary lockfile has null counts and no diff" \
  '. == [{path: "package-lock.json", renamedFrom: null, added: null, removed: null, generated: true, diff: null}]'

# renames: a pure rename is only listed, a rename with edits keeps one diff
bd_ren=$(mktemp -d "$tmp/bd-XXXXXX")
make_branch_repo "$bd_ren"
mkdir -p "$bd_ren/a" "$bd_ren/gen"
# every file has its own content: with equal contents git pairs the renames arbitrarily
for f in old.txt a/old.txt gen/old.js "my old.txt"; do
  for n in 1 2 3 4 5 6 7 8 9 10; do echo "$f line $n"; done > "$bd_ren/$f"
done
printf 'gen/* linguist-generated\n' > "$bd_ren/.gitattributes"
commit_all "$bd_ren"
git -C "$bd_ren" update-ref refs/remotes/origin/main HEAD
mkdir -p "$bd_ren/src" "$bd_ren/b/c"
git -C "$bd_ren" mv old.txt src/new.txt
git -C "$bd_ren" mv "my old.txt" "my new.txt"
git -C "$bd_ren" mv gen/old.js gen/new.js
git -C "$bd_ren" mv a/old.txt b/c/new.txt
sed 's/line 3$/changed/' "$bd_ren/b/c/new.txt" > "$bd_ren/b/c/new.tmp"
mv "$bd_ren/b/c/new.tmp" "$bd_ren/b/c/new.txt"
commit_all "$bd_ren"
bd_dir=$(mktemp -d "$tmp/folder-XXXXXX")
PLAIN_DIR="$bd_ren" run_plain "$diff_script" files origin main "$bd_dir"
expect_jq "branch-diff/rename: pure rename is listed with its old path and no diff" \
  '.[] | select(.path == "src/new.txt") == {path: "src/new.txt", renamedFrom: "old.txt", added: 0, removed: 0, generated: false, diff: null}'
expect_jq "branch-diff/rename: pure rename with a space in the names" \
  '.[] | select(.path == "my new.txt") | .renamedFrom == "my old.txt" and .diff == null'
expect_jq "branch-diff/rename: rename with edits keeps old path and a diff file" \
  '.[] | select(.path == "b/c/new.txt") | .renamedFrom == "a/old.txt" and .added == 1 and .removed == 1 and .generated == false and .diff != null'
expect_jq "branch-diff/rename: renamed generated file has no diff" \
  '.[] | select(.path == "gen/new.js") | .renamedFrom == "gen/old.js" and .generated == true and .diff == null'
expect_jq "branch-diff/rename: one entry per renamed file, no delete plus add" 'length == 4'
count=$(ls "$bd_dir/diff" | wc -l | tr -d ' ')
if [[ $count -eq 1 ]]; then report "branch-diff/rename: only the rename with edits gets a diff file" ok; else report "branch-diff/rename: only the rename with edits gets a diff file" fail "$count files"; fi
expect_in_file "branch-diff/rename: the diff shows the rename once" "$bd_dir/diff/001.diff" "rename from a/old.txt"
if grep -q "deleted file mode" "$bd_dir/diff/001.diff"; then report "branch-diff/rename: the diff is not a delete plus add" fail "deleted file mode found"; else report "branch-diff/rename: the diff is not a delete plus add" ok; fi

# user git config must not change the diff files
bd_cfg=$(mktemp -d "$tmp/bd-XXXXXX")
make_branch_repo "$bd_cfg"
git -C "$bd_cfg" config color.ui always
git -C "$bd_cfg" config diff.external /bin/true
printf 'x\n' > "$bd_cfg/new.txt"
commit_all "$bd_cfg"
bd_dir=$(mktemp -d "$tmp/folder-XXXXXX")
PLAIN_DIR="$bd_cfg" run_plain "$diff_script" files origin main "$bd_dir"
expect_in_file "branch-diff/config: diff file holds the change despite diff.external" "$bd_dir/diff/001.diff" "+x"
if grep -q $'\033' "$bd_dir/diff/001.diff"; then report "branch-diff/config: no color codes in the diff file" fail "escape code found"; else report "branch-diff/config: no color codes in the diff file" ok; fi
PLAIN_DIR="$bd_cfg" run_plain "$diff_script" file origin main new.txt
if grep -q $'\033' "$tmp/data.out"; then report "branch-diff/config: no color codes from file" fail "escape code found"; else report "branch-diff/config: no color codes from file" ok; fi

# file takes the old path of a renamed file
bd_moved=$(mktemp -d "$tmp/bd-XXXXXX")
make_branch_repo "$bd_moved"
mkdir -p "$bd_moved/lock"
for n in 1 2 3 4 5 6 7 8 9 10; do echo "lock line $n"; done > "$bd_moved/yarn.lock"
commit_all "$bd_moved"
git -C "$bd_moved" update-ref refs/remotes/origin/main HEAD
git -C "$bd_moved" mv yarn.lock lock/yarn.lock
echo "lock line 11" >> "$bd_moved/lock/yarn.lock"
commit_all "$bd_moved"
PLAIN_DIR="$bd_moved" run_plain "$diff_script" file origin main lock/yarn.lock yarn.lock
expect_in_file "branch-diff/file: old path shows the rename" "$tmp/data.out" "rename from yarn.lock"
expect_in_file "branch-diff/file: old path shows the change" "$tmp/data.out" "+lock line 11"
PLAIN_DIR="$bd_moved" run_plain "$diff_script" file origin main lock/yarn.lock a b
expect_error "branch-diff/usage: file with too many arguments" 2 usage false

PLAIN_DIR="$bd_repo" run_plain "$diff_script" files nowhere main "$bd_dir"
expect_error "branch-diff/unknown remote" 1 other false
PLAIN_DIR="$bd_repo" run_plain "$diff_script" files origin missing-branch "$bd_dir"
expect_error "branch-diff/unknown branch" 1 other false
PLAIN_DIR="$bd_repo" run_plain "$diff_script" file origin missing-branch base.txt
expect_error "branch-diff/file: unknown branch" 1 other false
PLAIN_DIR="$bd_repo" run_plain "$diff_script" files origin main "$tmp/no-such-folder"
expect_error "branch-diff/pr-dir missing" 1 other false
run_plain "$diff_script"
expect_error "branch-diff/usage: no arguments" 2 usage false
run_plain "$diff_script" bogus
expect_error "branch-diff/usage: unknown subcommand" 2 usage false
run_plain "$diff_script" files origin main
expect_error "branch-diff/usage: files with too few arguments" 2 usage false
run_plain "$diff_script" file origin main
expect_error "branch-diff/usage: file with too few arguments" 2 usage false

# ---- pr-body-check.sh ----
# The body of create-pr must name every changed file: as its path, below a directory entry, or in a brace pattern.

bc_script="$root/plugins/dotclaude-dev/scripts/pr-body-check.sh"

# bc_run <file-table-json>: the body comes from stdin; runs the check in a fresh folder
bc_run() {
  local table=$1 dir
  dir=$(mktemp -d "$tmp/bc-XXXXXX")
  cat > "$dir/body.txt"
  printf '%s\n' "$table" > "$dir/file-table.json"
  run_plain "$bc_script" "$dir"
  return 0
}

bc_run '[{"path":"a.ts"},{"path":"b.ts"},{"path":"my file.txt"}]' << 'EOF'
## What

x

## Why

y

## File risk

### 🔴 Critical

- `a.ts` — changed

### 🟡 Medium

- `my file.txt` — changed

### 🟢 Low

- `b.ts` — changed
EOF
expect_jq "pr-body-check/every file has its own entry" '.uncovered == [] and .fileRisk.state == "ok"'

bc_run '[{"path":"src/dir/x.ts"},{"path":"src/dir/sub/y.ts"},{"path":"src/dir2/z.ts"}]' << 'EOF'
## File risk

### 🟢 Low

- `src/dir/` — the folder (2 files)
EOF
expect_jq "pr-body-check/a directory entry covers what is below it and not a sibling directory with the same start" '.uncovered == ["src/dir2/z.ts"]'

bc_run '[{"path":"src/app/foo/foo.component.ts"},{"path":"src/app/foo/foo.component.spec.ts"},{"path":"src/app/foo/foo.component.html"},{"path":"src/app/foo/bar.component.ts"}]' << 'EOF'
## File risk

### 🟡 Medium

- `src/app/foo/foo.component.{ts,spec.ts}` — the component (2 files)
EOF
expect_jq "pr-body-check/a brace pattern covers exactly its expansions" '.uncovered == ["src/app/foo/foo.component.html", "src/app/foo/bar.component.ts"]'

bc_run '[{"path":"a.ts"},{"path":"yarn.lock"},{"path":"new/name.ts","renamedFrom":"old/name.ts"}]' << 'EOF'
## File risk

### 🟢 Low

- `a.ts` — changed
- `old/name.ts` — renamed
EOF
expect_jq "pr-body-check/a generated file and a rename need an entry, the old path does not count" '.uncovered == ["yarn.lock", "new/name.ts"]'

bc_run '[{"path":"a.ts"}]' << 'EOF'
## What

no file risk section at all
EOF
expect_jq "pr-body-check/without a File risk section nothing is covered" '.uncovered == ["a.ts"] and .fileRisk.state == "missing"'

bc_run '[]' << 'EOF'
## File risk

### 🟢 Low

- `extra.ts` — not part of the table
EOF
expect_jq "pr-body-check/an entry for an unchanged file is not an error" '.uncovered == []'

bc_run '[{"path":"a.ts"}]' << 'EOF'
## File risk

### 🟢 Low

- `a.ts` — changed

## Merge danger

Drops the column.

## Closes

Closes #4
EOF
expect_jq "pr-body-check/the parser result is part of the output" '.mergeDanger == "Drops the column." and .closes.numbers == [4]'

bc_dir=$(mktemp -d "$tmp/bc-XXXXXX")
run_plain "$bc_script" "$bc_dir"
expect_error "pr-body-check/no body.txt" 1 other false
printf '%s\n' '## File risk' > "$bc_dir/body.txt"
run_plain "$bc_script" "$bc_dir"
expect_error "pr-body-check/no file-table.json" 1 other false
printf '%s\n' 'not json' > "$bc_dir/file-table.json"
run_plain "$bc_script" "$bc_dir"
expect_error "pr-body-check/file-table.json is not JSON" 1 other false
run_plain "$bc_script"
expect_error "pr-body-check/usage: no arguments" 2 usage false

# ---- pr-checklist-parse.jq ----

checklist_parser="$root/plugins/dotclaude-dev/scripts/pr-checklist-parse.jq"
cl_count=$(jq length "$fixtures/checklist/cases.json")
i=0
while [[ $i -lt $cl_count ]]; do
  cl_fixture=$(jq -r ".[$i].fixture" "$fixtures/checklist/cases.json")
  jq ".[$i].expected" "$fixtures/checklist/cases.json" > "$tmp/cl-expected.json"
  jq -Rs -f "$checklist_parser" "$fixtures/checklist/$cl_fixture" > "$tmp/cl-actual.json" 2> "$tmp/err" || cat "$tmp/err"
  check "checklist-parse/$(jq -r ".[$i].name" "$fixtures/checklist/cases.json")" "$tmp/cl-actual.json" "$tmp/cl-expected.json"
  i=$((i + 1))
done

# CRLF is generated, not stored (like the body fixtures)
awk '{printf "%s\r\n", $0}' "$fixtures/checklist/ok-basic.txt" > "$tmp/crlf.txt"
jq -Rs -f "$checklist_parser" "$tmp/crlf.txt" > "$tmp/cl-actual.json" 2> "$tmp/err" || cat "$tmp/err"
jq '.[] | select(.name == "ok-basic") | .expected' "$fixtures/checklist/cases.json" > "$tmp/cl-expected.json"
check "checklist-parse/ok-basic (CRLF)" "$tmp/cl-actual.json" "$tmp/cl-expected.json"

printf '' > "$tmp/empty.txt"
jq -Rs -f "$checklist_parser" "$tmp/empty.txt" > "$tmp/cl-actual.json" 2> "$tmp/err" || cat "$tmp/err"
printf '%s\n' '{"state":"none","rows":[]}' > "$tmp/cl-expected.json"
check "checklist-parse/empty input" "$tmp/cl-actual.json" "$tmp/cl-expected.json"

# ---- pr-checklist.sh ----
# Each case builds a scratch repository: CLAUDE.md with a checklist is committed before origin/main is set, so it is not a change itself.

checklist_script="$root/plugins/dotclaude-dev/scripts/pr-checklist.sh"

# write_checklist <dir>: writes <dir>/CLAUDE.md; the table rows come from stdin as "pattern cell|item cell"
write_checklist() {
  local dir=$1 row
  {
    printf '# Project\n\n### PR merge checklist\n\n| File pattern | Checklist item |\n| --- | --- |\n'
    while IFS= read -r row; do printf '| %s | %s |\n' "${row%%|*}" "${row#*|}"; done
    printf '\n### Other\n'
  } > "$dir/CLAUDE.md"
  return 0
}

# make_checklist_repo <dir> <file>...: a branch repository whose CLAUDE.md checklist (rows from stdin) is on origin/main,
# with the given files added on the feature branch
make_checklist_repo() {
  local dir=$1 f
  shift
  make_branch_repo "$dir"
  write_checklist "$dir"
  commit_all "$dir"
  git -C "$dir" update-ref refs/remotes/origin/main HEAD
  for f in "$@"; do
    mkdir -p "$dir/$(dirname "$f")"
    echo x > "$dir/$f"
  done
  commit_all "$dir"
  return 0
}

cl_rows='`package.json`|Item concrete
`apps/api/migrations`|Item directory
`apps/**/migrations/*`|Item star
`apps/**/migrations/**`|Item deep
`./apps/web/**`|Item dot slash
`nothing.txt`, `docs/a.md`|Item list
`docs/*.md`|Item docs
`**/*.md`|Item docs
`unrelated/**`|Item unrelated'

cl_repo=$(mktemp -d "$tmp/cl-XXXXXX")
make_checklist_repo "$cl_repo" apps/api/migrations/sub/002.ts apps/web/x/page.ts docs/a.md package.json << EOT
$cl_rows
EOT
PLAIN_DIR="$cl_repo" run_plain "$checklist_script" origin main
expect_jq "pr-checklist/file, directory, **, ./, comma list, duplicates; * stays on one level" \
  '. == {state: "ok", items: ["Item concrete", "Item directory", "Item deep", "Item dot slash", "Item list", "Item docs"]}'
PLAIN_DIR="$cl_repo/apps" run_plain "$checklist_script" origin main
expect_jq "pr-checklist/from a subdirectory the result is the same" \
  '. == {state: "ok", items: ["Item concrete", "Item directory", "Item deep", "Item dot slash", "Item list", "Item docs"]}'

cl_star=$(mktemp -d "$tmp/cl-XXXXXX")
make_checklist_repo "$cl_star" apps/api/migrations/001.ts apps/migrations/003.ts << EOT
$cl_rows
EOT
PLAIN_DIR="$cl_star" run_plain "$checklist_script" origin main
expect_jq "pr-checklist/* matches direct children of a folder, ** also matches zero folders" \
  '. == {state: "ok", items: ["Item directory", "Item star", "Item deep"]}'

cl_none=$(mktemp -d "$tmp/cl-XXXXXX")
make_checklist_repo "$cl_none" src/other.txt << EOT
$cl_rows
EOT
PLAIN_DIR="$cl_none" run_plain "$checklist_script" origin main
expect_jq "pr-checklist/no row matches" '. == {state: "ok", items: []}'

cl_moved=$(mktemp -d "$tmp/cl-XXXXXX")
make_branch_repo "$cl_moved"
write_checklist "$cl_moved" << 'EOT'
`old/mig/**`|Item moved out
`gone.txt`|Item deleted
EOT
mkdir -p "$cl_moved/old/mig"
for n in 1 2 3 4 5 6 7 8 9 10; do echo "mig line $n"; done > "$cl_moved/old/mig/001.ts"
echo gone > "$cl_moved/gone.txt"
commit_all "$cl_moved"
git -C "$cl_moved" update-ref refs/remotes/origin/main HEAD
mkdir -p "$cl_moved/elsewhere"
git -C "$cl_moved" mv old/mig/001.ts elsewhere/001.ts
git -C "$cl_moved" rm -q gone.txt
commit_all "$cl_moved"
PLAIN_DIR="$cl_moved" run_plain "$checklist_script" origin main
expect_jq "pr-checklist/a file moved out of a folder and a deleted file both match" \
  '. == {state: "ok", items: ["Item moved out", "Item deleted"]}'

cl_missing=$(mktemp -d "$tmp/cl-XXXXXX")
make_branch_repo "$cl_missing"
echo x > "$cl_missing/new.txt"
commit_all "$cl_missing"
PLAIN_DIR="$cl_missing" run_plain "$checklist_script" origin main
expect_jq "pr-checklist/no CLAUDE.md" '. == {state: "none", items: []}'

cl_sub=$(mktemp -d "$tmp/cl-XXXXXX")
make_branch_repo "$cl_sub"
mkdir -p "$cl_sub/sub"
write_checklist "$cl_sub/sub" << 'EOT'
`new.txt`|Item from a subfolder
EOT
echo x > "$cl_sub/new.txt"
commit_all "$cl_sub"
PLAIN_DIR="$cl_sub" run_plain "$checklist_script" origin main
expect_jq "pr-checklist/a CLAUDE.md in a subfolder is not read" '. == {state: "none", items: []}'

cl_outer=$(mktemp -d "$tmp/cl-XXXXXX")
write_checklist "$cl_outer" << 'EOT'
`new.txt`|Item from the parent folder
EOT
make_branch_repo "$cl_outer/inner"
echo x > "$cl_outer/inner/new.txt"
commit_all "$cl_outer/inner"
PLAIN_DIR="$cl_outer/inner" run_plain "$checklist_script" origin main
expect_jq "pr-checklist/a CLAUDE.md in a parent folder is not read" '. == {state: "none", items: []}'

cl_bad=$(mktemp -d "$tmp/cl-XXXXXX")
make_branch_repo "$cl_bad"
printf '### PR merge checklist\n\nTable follows later.\n' > "$cl_bad/CLAUDE.md"
echo x > "$cl_bad/new.txt"
commit_all "$cl_bad"
PLAIN_DIR="$cl_bad" run_plain "$checklist_script" origin main
expect_jq "pr-checklist/heading without a table is unusable, not an error" '. == {state: "unusable", items: []}'

cl_plain=$(mktemp -d "$tmp/cl-XXXXXX")
make_branch_repo "$cl_plain"
printf '# Project\n\nNo checklist.\n' > "$cl_plain/CLAUDE.md"
commit_all "$cl_plain"
PLAIN_DIR="$cl_plain" run_plain "$checklist_script" origin missing-branch
expect_jq "pr-checklist/no checklist heading does not need the remote branch" '. == {state: "none", items: []}'
PLAIN_DIR="$cl_bad" run_plain "$checklist_script" origin missing-branch
expect_jq "pr-checklist/an unusable table does not need the remote branch" '. == {state: "unusable", items: []}'

PLAIN_DIR="$cl_repo" run_plain "$checklist_script" origin missing-branch
expect_error "pr-checklist/unknown remote-tracking branch" 1 other false
checklist_message=$(jq -r '.message' "$tmp/data.err")
PLAIN_DIR="$bd_repo" run_plain "$diff_script" files origin missing-branch "$(mktemp -d "$tmp/folder-XXXXXX")"
if [[ $(jq -r '.message' "$tmp/data.err") == "$checklist_message" ]]; then
  report "set_range: branch-diff and pr-checklist give the same message for a missing branch" ok
else
  report "set_range: branch-diff and pr-checklist give the same message for a missing branch" fail "checklist: $checklist_message"$'\n'"branch-diff: $(cat "$tmp/data.err")"
fi
run_plain "$checklist_script" origin
expect_error "pr-checklist/usage: one argument" 2 usage false
run_plain "$checklist_script" origin main extra
expect_error "pr-checklist/usage: three arguments" 2 usage false

# ---- git failures: run_git puts git's own reason into the message ----

# make_lone_repo <dir>: HEAD shares no history with origin/main, so every diff against it fails (no merge base)
make_lone_repo() {
  local dir=$1
  make_branch_repo "$dir"
  git -C "$dir" checkout -q --orphan lone
  git -C "$dir" rm -rfq .
  write_checklist "$dir" << 'EOT'
`new.txt`|Item new
EOT
  echo x > "$dir/new.txt"
  commit_all "$dir"
  return 0
}

rg_lone=$(mktemp -d "$tmp/lone-XXXXXX")
make_lone_repo "$rg_lone"
rg_dir=$(mktemp -d "$tmp/folder-XXXXXX")
# git's messages are translated: LC_ALL=C makes the text comparable
LC_ALL=C PLAIN_DIR="$rg_lone" run_plain "$checklist_script" origin main
expect_error_text "run_git/pr-checklist: no merge base is one error line" 1 other false "no merge base"
LC_ALL=C PLAIN_DIR="$rg_lone" run_plain "$diff_script" files origin main "$rg_dir"
expect_error_text "run_git/branch-diff files: no merge base is one error line" 1 other false "no merge base"

rg_bare=$(mktemp -d "$tmp/bare-XXXXXX")
LC_ALL=C PLAIN_DIR="$rg_bare" run_plain "$checklist_script" origin main
expect_error_text "run_git/pr-checklist: outside a repository" 1 other false "$not_in_repo"
LC_ALL=C PLAIN_DIR="$rg_bare" run_plain "$diff_script" files origin main "$(mktemp -d "$tmp/folder-XXXXXX")"
expect_error_text "run_git/branch-diff files: outside a repository" 1 other false "$not_in_repo"
LC_ALL=C PLAIN_DIR="$rg_bare" run_plain "$diff_script" file origin main base.txt
expect_error_text "require_repo/branch-diff file: outside a repository" 1 other false "$not_in_repo"

# ---- branch-state.sh ----
# The "remotes" are local bare repositories, so the script really fetches from them.

bs_script="$root/plugins/dotclaude-dev/scripts/branch-state.sh"

# make_bs_repo <dir>: <dir>/origin.git (bare) and <dir>/work, a clone on the branch feat that tracks origin/feat and is in sync
make_bs_repo() {
  local dir=$1
  git init -q --bare "$dir/origin.git"
  git -C "$dir/origin.git" symbolic-ref HEAD refs/heads/main
  git init -q "$dir/work"
  git -C "$dir/work" symbolic-ref HEAD refs/heads/main
  git -C "$dir/work" config user.name tester
  git -C "$dir/work" config user.email tester@example.com
  git -C "$dir/work" remote add origin "$dir/origin.git"
  echo a > "$dir/work/a.txt"
  git -C "$dir/work" add -A
  git -C "$dir/work" commit -q -m A
  git -C "$dir/work" push -q origin main
  git -C "$dir/work" checkout -q -b feat
  echo f > "$dir/work/f.txt"
  git -C "$dir/work" add -A
  git -C "$dir/work" commit -q -m F
  git -C "$dir/work" push -q -u origin feat
  return 0
}

# bs_commit <repo> <file>: one more commit
bs_commit() {
  local repo=$1 file=$2
  echo "$file" > "$repo/$file"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "$file"
  return 0
}

bs_root=$(mktemp -d "$tmp/bs-XXXXXX")
make_bs_repo "$bs_root"
PLAIN_DIR="$bs_root/work" run_plain "$bs_script"
expect_jq "branch-state/in sync: branch, remote and remote branch" '. == {branch: "feat", remote: "origin", remoteBranch: "feat"}'

git -C "$bs_root/work" checkout -q --detach
PLAIN_DIR="$bs_root/work" run_plain "$bs_script" create-pr
git -C "$bs_root/work" checkout -q feat
expect_error_text "branch-state/detached HEAD" 1 other false "Not on a branch"
expect_error_message "branch-state/detached HEAD, the hint names the skill" '`/create-pr`'

git -C "$bs_root/work" checkout -q -b loose
PLAIN_DIR="$bs_root/work" run_plain "$bs_script"
expect_error_text "branch-state/no upstream" 1 other false "has no remote tracking branch"
expect_error_message "branch-state/no upstream, the push command names the branch" "git push -u origin loose"

# the upstream is a local branch: the old text took its name for a remote and said "check your network"
git -C "$bs_root/work" checkout -q -b follows-main --track main
PLAIN_DIR="$bs_root/work" run_plain "$bs_script"
expect_error_text "branch-state/the upstream is a local branch" 1 other false "local branch"
git -C "$bs_root/work" checkout -q feat

# local and remote branch names differ
git -C "$bs_root/work" checkout -q -b fix-x
bs_commit "$bs_root/work" x
git -C "$bs_root/work" push -q -u origin fix-x:fix/x-new
PLAIN_DIR="$bs_root/work" run_plain "$bs_script"
expect_jq "branch-state/different local and remote branch names" '. == {branch: "fix-x", remote: "origin", remoteBranch: "fix/x-new"}'
git -C "$bs_root/work" checkout -q feat

# a branch name with a dot and a slash, and a remote name with a slash
git -C "$bs_root/work" checkout -q -b topic/a.b
bs_commit "$bs_root/work" ab
git init -q --bare "$bs_root/fork.git"
git -C "$bs_root/work" remote add my/fork "$bs_root/fork.git"
git -C "$bs_root/work" push -q -u my/fork topic/a.b
PLAIN_DIR="$bs_root/work" run_plain "$bs_script"
expect_jq "branch-state/a remote name with a slash and a branch name with a dot" '. == {branch: "topic/a.b", remote: "my/fork", remoteBranch: "topic/a.b"}'
git -C "$bs_root/work" checkout -q feat

# behind, ahead and both: the stop names the upstream and the hint the skill
bs_behind=$(mktemp -d "$tmp/bs-XXXXXX")
make_bs_repo "$bs_behind"
git clone -q "$bs_behind/origin.git" "$bs_behind/other"
git -C "$bs_behind/other" config user.name tester
git -C "$bs_behind/other" config user.email tester@example.com
git -C "$bs_behind/other" checkout -q feat
bs_commit "$bs_behind/other" more
git -C "$bs_behind/other" push -q origin feat
PLAIN_DIR="$bs_behind/work" run_plain "$bs_script" create-pr
expect_error_text "branch-state/behind the remote" 1 other false "behind origin/feat"
expect_error_message "branch-state/behind the remote, hint" 'then re-run `/create-pr`.'

bs_commit "$bs_behind/work" mine
PLAIN_DIR="$bs_behind/work" run_plain "$bs_script"
expect_error_text "branch-state/both behind and ahead" 1 other false "behind origin/feat"

bs_ahead=$(mktemp -d "$tmp/bs-XXXXXX")
make_bs_repo "$bs_ahead"
bs_commit "$bs_ahead/work" mine
PLAIN_DIR="$bs_ahead/work" run_plain "$bs_script"
expect_error_text "branch-state/ahead of the remote" 1 other false "not on origin/feat yet"

# the remote is configured but its repository cannot be fetched
bs_broken=$(mktemp -d "$tmp/bs-XXXXXX")
make_bs_repo "$bs_broken"
git -C "$bs_broken/work" config remote.origin.url "$bs_broken/no-such-repo.git"
PLAIN_DIR="$bs_broken/work" run_plain "$bs_script"
expect_error_text "branch-state/the fetch fails" 1 other false "Could not fetch origin"

# the branch config names a remote that does not exist
bs_gone=$(mktemp -d "$tmp/bs-XXXXXX")
make_bs_repo "$bs_gone"
git -C "$bs_gone/work" config branch.feat.remote gone
PLAIN_DIR="$bs_gone/work" run_plain "$bs_script"
expect_error_text "branch-state/the configured remote does not exist" 1 other false "No remote named gone"

PLAIN_DIR="$rg_bare" run_plain "$bs_script"
expect_error_text "branch-state/outside a repository" 1 other false "$not_in_repo"
run_plain "$bs_script" a b
expect_error "branch-state/usage: two arguments" 2 usage false
run_plain "$bs_script" other-skill
expect_error "branch-state/usage: an unknown skill" 2 usage false

# ---- preflight.sh ----

preflight_script="$root/plugins/dotclaude-dev/scripts/preflight.sh"
pf_repo=$(mktemp -d "$tmp/pf-repo-XXXXXX")
git -C "$pf_repo" init -q
git -C "$pf_repo" remote add origin https://github.example.local/o/r.git

# pf_branch_repo <branch> [no-upstream]: a repository for create-pr on that branch; the upstream is origin/<branch>, already fetched
pf_branch_repo() {
  local branch=$1 upstream=${2:-} dir
  dir=$(mktemp -d "$tmp/pf-repo-XXXXXX")
  git -C "$dir" init -q
  git -C "$dir" symbolic-ref HEAD "refs/heads/$branch"
  git -C "$dir" config user.name tester
  git -C "$dir" config user.email tester@example.com
  git -C "$dir" remote add origin https://github.example.local/o/r.git
  echo a > "$dir/a.txt"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m A
  if [[ $upstream != no-upstream ]]; then
    git -C "$dir" config "branch.$branch.remote" origin
    git -C "$dir" config "branch.$branch.merge" "refs/heads/$branch"
    git -C "$dir" update-ref "refs/remotes/origin/$branch" HEAD
  fi
  printf '%s\n' "$dir"
  return 0
}
pf_cp_repo=$(pf_branch_repo feat)

# pf_stub: the fake gh answers the login and the repository
pf_stub() {
  local dir
  dir=$(new_stub)
  echo reviewer1 > "$dir/api-user.out"
  echo '{"url":"https://github.example.local/o/r","nameWithOwner":"o/r","defaultBranchRef":{"name":"main"}}' > "$dir/repo-view.out"
  printf '%s\n' "$dir"
  return 0
}

# pf_run <stub-dir> <tmp-dir> <arguments...>: runs preflight.sh with the fake gh and its own TMPDIR, in the branch repository for create-pr
# (PF_REPO overrides it) and in the plain one for review-pr; the fetch of the branch check is skipped
pf_run() {
  local stub=$1 work_dir=$2 repo=$pf_repo skill
  shift 2
  skill=${1:-}
  [[ $skill != create-pr ]] || repo=$pf_cp_repo
  STUB_GIT_FETCH=skip STUB_GH_DIR="$stub" TMPDIR="$work_dir" PLAIN_DIR="${PF_REPO:-$repo}" run_plain "$preflight_script" "$@"
  return 0
}

# expect_no_pr_folder <name> <tmp-dir>: no create-pr-* or review-pr-* folder was made (the scripts' scratch files in dotclaude-dev are fine)
expect_no_pr_folder() {
  local name=$1 work_dir=$2 found
  found=$(ls "$work_dir/dotclaude-dev" 2> /dev/null | grep -E '^(create-pr|review-pr)-' || true)
  if [[ -z $found ]]; then
    report "$name" ok
  else
    report "$name" fail "folders: $found"
  fi
  return 0
}

pf_tmp=$(mktemp -d "$tmp/pf-tmp-XXXXXX")
stub=$(pf_stub)
pf_run "$stub" "$pf_tmp" create-pr
pf_dir=$(jq -r '.prDir' "$tmp/data.out")
if [[ $DATA_CODE -eq 0 ]] && jq -e --arg dir "$pf_dir" '. == {skill: "create-pr", remote: "origin", remoteUrl: "https://github.example.local/o/r.git", host: "github.example.local", username: "reviewer1", repoUrl: "https://github.example.local/o/r", repoPath: "o/r", defaultBranch: "main", prDir: $dir, branch: "feat", remoteBranch: "feat"}' "$tmp/data.out" > /dev/null; then
  report "preflight/create-pr: the printed JSON" ok
else
  report "preflight/create-pr: the printed JSON" fail "exit $DATA_CODE: $(cat "$tmp/data.out") $(cat "$tmp/data.err")"
fi
check "preflight/create-pr: preflight.json holds the printed JSON" "$pf_dir/preflight.json" "$tmp/data.out"
[[ $pf_dir == "$pf_tmp"/dotclaude-dev/create-pr-* ]] &&
  report "preflight/create-pr: folder under TMPDIR, named after the skill" ok ||
  report "preflight/create-pr: folder under TMPDIR, named after the skill" fail "$pf_dir"
expect_call "preflight/create-pr: login is read on the host of the remote" "$stub" "api user --hostname github.example.local"
expect_call "preflight/create-pr: the repository is read from the remote URL" "$stub" "repo view https://github.example.local/o/r.git"

pf_run "$stub" "$pf_tmp" review-pr origin
jq -e '.skill == "review-pr" and (.prDir | test("/review-pr-[A-Za-z0-9]+$")) and (has("branch") | not) and (has("remoteBranch") | not)' "$tmp/data.out" > /dev/null &&
  report "preflight/review-pr: folder prefix and skill" ok ||
  report "preflight/review-pr: folder prefix and skill" fail "$(cat "$tmp/data.out") $(cat "$tmp/data.err")"

# every failure leaves no folder behind and names the skill in the hint
pf_case_tmp=$(mktemp -d "$tmp/pf-case-XXXXXX")
PLAIN_DIR="$rg_bare" TMPDIR="$pf_case_tmp" run_plain "$preflight_script" create-pr
expect_error_text "preflight/outside a repository" 1 other false '`/create-pr`'
expect_no_pr_folder "preflight/outside a repository makes no folder" "$pf_case_tmp"

pf_run "$stub" "$pf_case_tmp" review-pr nowhere
expect_error_text "preflight/unknown remote" 1 other false "No remote named nowhere"
expect_no_pr_folder "preflight/unknown remote makes no folder" "$pf_case_tmp"

stub=$(pf_stub)
fail_stub "$stub" api-user 4 "authentication required"
pf_run "$stub" "$pf_case_tmp" review-pr origin
expect_error_text "preflight/auth failure" 10 auth false '`/review-pr`'
expect_no_pr_folder "preflight/auth failure makes no folder" "$pf_case_tmp"

stub=$(pf_stub)
fail_stub "$stub" repo-view 1 "GraphQL: Could not resolve to a Repository with the name 'o/r'."
pf_run "$stub" "$pf_case_tmp" create-pr
expect_error "preflight/repository not found" 11 not_found false
expect_no_pr_folder "preflight/repository not found makes no folder" "$pf_case_tmp"

stub=$(pf_stub)
echo '{"url":"https://github.example.local/o/r","nameWithOwner":"o/r","defaultBranchRef":null}' > "$stub/repo-view.out"
pf_run "$stub" "$pf_case_tmp" create-pr
expect_error_text "preflight/repository without a default branch" 1 other false "no default branch"
expect_no_pr_folder "preflight/repository without a default branch makes no folder" "$pf_case_tmp"

stub=$(pf_stub)
pf_blocked=$(mktemp -d "$tmp/pf-blocked-XXXXXX")
: > "$pf_blocked/dotclaude-dev"
pf_run "$stub" "$pf_blocked" create-pr
expect_error_text "preflight/temporary folder cannot be created" 1 other false "temporary folder"

pf_run "$stub" "$pf_case_tmp" other-skill origin
expect_error "preflight/usage: unknown skill" 2 usage false
pf_run "$stub" "$pf_case_tmp" review-pr
expect_error "preflight/usage: review-pr without a remote" 2 usage false
pf_run "$stub" "$pf_case_tmp" create-pr origin
expect_error "preflight/usage: create-pr finds its remote itself" 2 usage false
pf_run "$stub" "$pf_case_tmp" review-pr origin extra
expect_error_text "preflight/usage: three arguments" 2 usage false "Wrong arguments. Usage: preflight.sh create-pr | review-pr <remote>, see the header of the script."
expect_no_pr_folder "preflight/usage errors make no folder" "$pf_case_tmp"

# create-pr: the branch checks come first, so a failure makes no gh call and no folder
stub=$(pf_stub)
PF_REPO=$(pf_branch_repo loose no-upstream) pf_run "$stub" "$pf_case_tmp" create-pr
expect_error_text "preflight/create-pr: a branch without upstream" 1 other false "has no remote tracking branch"
expect_error_message "preflight/create-pr: a branch without upstream, hint names the skill" '`/create-pr`'
expect_no_pr_folder "preflight/create-pr: a branch without upstream makes no folder" "$pf_case_tmp"
[[ ! -f $stub/calls.log ]] && report "preflight/create-pr: a branch without upstream makes no gh call" ok ||
  report "preflight/create-pr: a branch without upstream makes no gh call" fail "$(cat "$stub/calls.log")"

# create-pr on the default branch: the guard needs the default branch from gh, still no folder
stub=$(pf_stub)
PF_REPO=$(pf_branch_repo main) pf_run "$stub" "$pf_case_tmp" create-pr
expect_error_text "preflight/create-pr: on the default branch" 1 other false "Branch main is the default branch"
expect_error_message "preflight/create-pr: on the default branch, hint names the skill" '`/create-pr`'
expect_no_pr_folder "preflight/create-pr: on the default branch makes no folder" "$pf_case_tmp"

# a password in the remote URL reaches neither the printed JSON, preflight.json, the gh call nor an error line
pf_cred_repo=$(mktemp -d "$tmp/pf-repo-XXXXXX")
git -C "$pf_cred_repo" init -q
git -C "$pf_cred_repo" remote add origin https://user:SECRET@github.example.local/o/r.git
pf_cred_tmp=$(mktemp -d "$tmp/pf-tmp-XXXXXX")
stub=$(pf_stub)
STUB_GH_DIR="$stub" TMPDIR="$pf_cred_tmp" PLAIN_DIR="$pf_cred_repo" run_plain "$preflight_script" review-pr origin
pf_dir=$(jq -r '.prDir' "$tmp/data.out")
if [[ $DATA_CODE -eq 0 ]] && ! grep -rq SECRET "$tmp/data.out" "$tmp/data.err" "$pf_dir" "$stub/calls.log" &&
  jq -e '.remoteUrl == "https://github.example.local/o/r.git"' "$pf_dir/preflight.json" > /dev/null; then
  report "preflight/a password in the remote URL is dropped everywhere" ok
else
  report "preflight/a password in the remote URL is dropped everywhere" fail "exit $DATA_CODE: $(cat "$tmp/data.out") $(cat "$tmp/data.err")"
fi
stub=$(new_stub)
echo reviewer1 > "$stub/api-user.out"
fail_stub "$stub" repo-view 1 "GraphQL: Could not resolve to a Repository (repository)"
STUB_GH_DIR="$stub" TMPDIR="$pf_cred_tmp" PLAIN_DIR="$pf_cred_repo" run_plain "$preflight_script" review-pr origin
if [[ $DATA_CODE -eq 11 ]] && ! grep -q SECRET "$tmp/data.err"; then
  report "preflight/a password in the remote URL is dropped from the error line" ok
else
  report "preflight/a password in the remote URL is dropped from the error line" fail "exit $DATA_CODE: $(cat "$tmp/data.err")"
fi

# ---- contract.sh: require_repo, load_preflight, the skill hint ----

# contract-call.sh <function> <arguments...>: calls one function of contract.sh, then prints HOST, REPO_URL, REPO_PATH and SKILL; TEST_SKILL pre-sets SKILL
cat > "$tmp/contract-call.sh" << 'EOT'
SCRIPT="contract-call.sh"
SUBCOMMANDS='<function>'
source "$CONTRACT_FILE"
SKILL=${TEST_SKILL:-}
fn=$1
shift
"$fn" "$@"
printf '%s|%s|%s|%s\n' "$HOST" "$REPO_URL" "$REPO_PATH" "$SKILL"
EOT
export CONTRACT_FILE="$root/plugins/dotclaude-dev/scripts/contract.sh"

PLAIN_DIR="$bd_repo" run_plain "$tmp/contract-call.sh" require_repo
expect_text "require_repo/inside a repository passes" "$tmp/data.out" "|||"
PLAIN_DIR="$rg_bare" run_plain "$tmp/contract-call.sh" require_repo
expect_error "require_repo/outside a repository" 1 other false
jq -e '.message | endswith("then re-run.")' "$tmp/data.err" > /dev/null 2>&1 &&
  report "require_repo/message without a skill ends with the plain hint" ok ||
  report "require_repo/message without a skill ends with the plain hint" fail "$(cat "$tmp/data.err")"
TEST_SKILL=create-pr PLAIN_DIR="$rg_bare" run_plain "$tmp/contract-call.sh" require_repo
jq -e '.message | endswith("then re-run `/create-pr`.")' "$tmp/data.err" > /dev/null 2>&1 &&
  report "require_repo/message with a skill names it" ok ||
  report "require_repo/message with a skill names it" fail "$(cat "$tmp/data.err")"

lp_dir=$(mktemp -d "$tmp/preflight-XXXXXX")
cat > "$lp_dir/preflight.json" << 'EOT'
{"skill":"review-pr","host":"github.example.local","repoUrl":"https://github.example.local/o/r","repoPath":"o/r","prDir":"x"}
EOT
run_plain "$tmp/contract-call.sh" load_preflight "$lp_dir"
expect_text "load_preflight/sets host, repo URL, repo path and skill" "$tmp/data.out" "github.example.local|https://github.example.local/o/r|o/r|review-pr"

lp_no_skill_field=$(mktemp -d "$tmp/preflight-XXXXXX")
echo '{"host":"h","repoUrl":"u","repoPath":"o/r"}' > "$lp_no_skill_field/preflight.json"
run_plain "$tmp/contract-call.sh" load_preflight "$lp_no_skill_field"
expect_text "load_preflight/a file without skill leaves it empty" "$tmp/data.out" "h|u|o/r|"

lp_missing=$(mktemp -d "$tmp/preflight-XXXXXX")
run_plain "$tmp/contract-call.sh" load_preflight "$lp_missing"
expect_error_text "load_preflight/folder without preflight.json" 1 other false "Run preflight first"

lp_partial=$(mktemp -d "$tmp/preflight-XXXXXX")
echo '{"skill":"create-pr","host":"h"}' > "$lp_partial/preflight.json"
run_plain "$tmp/contract-call.sh" load_preflight "$lp_partial"
expect_error_text "load_preflight/a file without repoUrl and repoPath" 1 other false "lacks host, repoUrl or repoPath"

lp_bad=$(mktemp -d "$tmp/preflight-XXXXXX")
echo 'not json' > "$lp_bad/preflight.json"
run_plain "$tmp/contract-call.sh" load_preflight "$lp_bad"
expect_error_text "load_preflight/a file that is not JSON" 1 other false "Cannot read"

# write_file: the file holds the content, a failed write ends in the contract error and leaves no partial file behind
# expect_no_tmp <name> <dir>: no .tmp-* file left from write_file
expect_no_tmp() {
  local name=$1 dir=$2 left
  left=$(ls -A "$dir" | grep '^\.tmp-' || true)
  if [[ -z $left ]]; then
    report "$name" ok
  else
    report "$name" fail "left: $left"
  fi
  return 0
}

wf_dir=$(mktemp -d "$tmp/wf-XXXXXX")
run_plain "$tmp/contract-call.sh" write_file "$wf_dir" out.txt "hello"
expect_text "write_file/writes the content" "$wf_dir/out.txt" "hello"
expect_no_tmp "write_file/leaves no temporary file" "$wf_dir"
run_plain "$tmp/contract-call.sh" write_file "$wf_dir" out.txt "second"
expect_text "write_file/replaces an existing file" "$wf_dir/out.txt" "second"

run_plain "$tmp/contract-call.sh" write_file "$tmp/no-such-wf-folder" out.txt "x"
expect_error_text "write_file/missing folder" 1 other false "does not exist"

# the temporary file is made, but moving it to the final name fails: the temporary file is removed again
run_plain "$tmp/contract-call.sh" write_file "$wf_dir" "no-such-sub/out.txt" "x"
expect_error_text "write_file/the move to the final name fails" 1 other false "Cannot write"
expect_no_tmp "write_file/a failed move leaves no temporary file" "$wf_dir"

if [[ $(id -u) -eq 0 ]]; then
  echo "skip  write_file/read-only folder (root ignores folder permissions)"
else
  wf_ro=$(mktemp -d "$tmp/wf-XXXXXX")
  chmod 500 "$wf_ro"
  run_plain "$tmp/contract-call.sh" write_file "$wf_ro" out.txt "x"
  chmod 700 "$wf_ro"
  expect_error_text "write_file/read-only folder" 1 other false "Cannot write to"
  expect_absent "write_file/read-only folder writes nothing" "$wf_ro/out.txt"
fi

# every gh error class ends with the skill as a command when a skill is known, and with the plain hint otherwise
while IFS='|' read -r label gh_exit stderr_text; do
  stub=$(new_stub)
  rm -f "$stub/pr-view.args" # this call is a bare run_gh, not one of the scripts' calls
  fail_stub "$stub" pr-view "$gh_exit" "$stderr_text"
  TEST_SKILL=create-pr run_stub "$stub" "$tmp/contract-call.sh" run_gh "the PR" pr view 1
  with_skill=$(jq -e '.message | endswith("then re-run `/create-pr`.")' "$tmp/data.err" > /dev/null 2>&1 && echo ok || cat "$tmp/data.err")
  run_stub "$stub" "$tmp/contract-call.sh" run_gh "the PR" pr view 1
  without_skill=$(jq -e '.message | endswith("then re-run.")' "$tmp/data.err" > /dev/null 2>&1 && echo ok || cat "$tmp/data.err")
  if [[ $with_skill == ok && $without_skill == ok ]]; then
    report "hint/$label names the skill when one is known and keeps the plain text otherwise" ok
  else
    report "hint/$label names the skill when one is known and keeps the plain text otherwise" fail "with skill: $with_skill; without: $without_skill"
  fi
done << 'EOT'
auth|4|authentication required
rate limit|1|gh: API rate limit exceeded (HTTP 403)
not found|1|gh: Not Found (HTTP 404)
network|1|error connecting to github.example.local
EOT

# ---- pr-refs.sh ----
# A bare "origin" holds main (commits A, then B) and refs/pull/7/head (commit F, cut from A); "user" is a clone that does not have F yet.

refs_script="$root/plugins/dotclaude-dev/scripts/pr-refs.sh"

# make_refs_repos <dir>: builds <dir>/origin.git, <dir>/work and <dir>/user; sets REFS_A (the commit the PR was cut from) and REFS_F (the PR head)
make_refs_repos() {
  local dir=$1
  git init -q --bare "$dir/origin.git"
  git -C "$dir/origin.git" symbolic-ref HEAD refs/heads/main
  git init -q "$dir/work"
  git -C "$dir/work" symbolic-ref HEAD refs/heads/main
  git -C "$dir/work" config user.name tester
  git -C "$dir/work" config user.email tester@example.com
  git -C "$dir/work" remote add origin "$dir/origin.git"
  echo a > "$dir/work/a.txt"
  git -C "$dir/work" add -A
  git -C "$dir/work" commit -q -m A
  REFS_A=$(git -C "$dir/work" rev-parse HEAD)
  git -C "$dir/work" checkout -q -b feat
  echo f > "$dir/work/f.txt"
  git -C "$dir/work" add -A
  git -C "$dir/work" commit -q -m F
  REFS_F=$(git -C "$dir/work" rev-parse HEAD)
  git -C "$dir/work" push -q origin "$REFS_F:refs/pull/7/head"
  git -C "$dir/work" checkout -q main
  echo b > "$dir/work/b.txt"
  git -C "$dir/work" add -A
  git -C "$dir/work" commit -q -m B
  git -C "$dir/work" push -q origin main
  git clone -q "$dir/origin.git" "$dir/user"
  return 0
}

# refs_folder <number> <head> <base>: a work folder whose preflight.json names the remote origin and whose pr.json holds the three fields
refs_folder() {
  local number=$1 head=$2 base=$3 dir
  dir=$(new_work)
  printf '%s\n' '{"host":"github.example.local","repoUrl":"https://github.example.local/o/r","repoPath":"o/r","remote":"origin","skill":"review-pr"}' > "$dir/preflight.json"
  jq -n --argjson number "$number" --arg head "$head" --arg base "$base" '{number: $number, headRefOid: $head, baseRefName: $base}' > "$dir/pr.json"
  printf '%s\n' "$dir"
  return 0
}

refs_root=$(mktemp -d "$tmp/refs-XXXXXX")
make_refs_repos "$refs_root"
refs_user="$refs_root/user"

dir=$(refs_folder 7 "$REFS_F" main)
PLAIN_DIR="$refs_user" run_plain "$refs_script" "$dir"
expect_jq "pr-refs/the merge base is the commit the PR was cut from, although main moved on" '. == {mergeBase: $a}' --arg a "$REFS_A"
git -C "$refs_user" cat-file -e "$REFS_F^{commit}" 2> /dev/null &&
  report "pr-refs/the PR head is fetched" ok || report "pr-refs/the PR head is fetched" fail "commit $REFS_F missing in the clone"
[[ $(git -C "$refs_user" branch --show-current) == main ]] &&
  report "pr-refs/the checked-out branch of the clone stays as it was" ok ||
  report "pr-refs/the checked-out branch of the clone stays as it was" fail "$(git -C "$refs_user" branch --show-current)"

# a base branch name is data: shell characters in it reach git as one argument and run nothing
for odd_base in 'x;touch-pwned' 'x$(id)' "x'quote"; do
  git -C "$refs_root/work" push -q origin "main:refs/heads/$odd_base"
  dir=$(refs_folder 7 "$REFS_F" "$odd_base")
  PLAIN_DIR="$refs_user" run_plain "$refs_script" "$dir"
  expect_jq "pr-refs/base branch name $odd_base" '. == {mergeBase: $a}' --arg a "$REFS_A"
done

dir=$(refs_folder 9 "$REFS_F" main)
PLAIN_DIR="$refs_user" run_plain "$refs_script" "$dir"
expect_error_text "pr-refs/the PR head cannot be fetched" 1 other false "Could not fetch the head of PR 9"

# the PR was force-pushed after pr.json was written: the commit pr.json names is not part of the fetched head
dir=$(refs_folder 7 "$REFS_A" main)
jq '.headRefOid = "0123456789012345678901234567890123456789"' "$dir/pr.json" > "$dir/pr.new" && mv "$dir/pr.new" "$dir/pr.json"
PLAIN_DIR="$refs_user" run_plain "$refs_script" "$dir"
expect_error_text "pr-refs/the commit of pr.json is gone after a force-push" 1 other false "force-pushed"

dir=$(refs_folder 7 "$REFS_F" no-such-base)
PLAIN_DIR="$refs_user" run_plain "$refs_script" "$dir"
expect_error_text "pr-refs/the base branch does not exist" 1 other false "Could not fetch base branch no-such-base"

# a base branch without any common commit with the PR head
git -C "$refs_root/work" checkout -q --orphan unrelated
git -C "$refs_root/work" rm -rfq .
echo u > "$refs_root/work/u.txt"
git -C "$refs_root/work" add -A
git -C "$refs_root/work" commit -q -m unrelated
git -C "$refs_root/work" push -q origin unrelated
dir=$(refs_folder 7 "$REFS_F" unrelated)
PLAIN_DIR="$refs_user" run_plain "$refs_script" "$dir"
expect_error_text "pr-refs/no common commit" 1 other false "merge base"

# pr.json is read as data: what is not a number or a commit id is refused before git runs
for bad in '{"number":"7;x","headRefOid":"'"$REFS_F"'","baseRefName":"main"}' '{"number":7,"headRefOid":"not-a-commit","baseRefName":"main"}' '{"number":7,"headRefOid":"'"$REFS_F"'","baseRefName":""}' '{"number":7,"headRefOid":"'"$REFS_F"'"}'; do
  dir=$(refs_folder 7 "$REFS_F" main)
  printf '%s\n' "$bad" > "$dir/pr.json"
  PLAIN_DIR="$refs_user" run_plain "$refs_script" "$dir"
  expect_error "pr-refs/unusable pr.json: $bad" 1 other false
done

dir=$(refs_folder 7 "$REFS_F" main)
rm -f "$dir/pr.json"
PLAIN_DIR="$refs_user" run_plain "$refs_script" "$dir"
expect_error "pr-refs/no pr.json" 1 other false
dir=$(refs_folder 7 "$REFS_F" main)
printf '%s\n' '{"host":"github.example.local","repoUrl":"https://github.example.local/o/r","repoPath":"o/r"}' > "$dir/preflight.json"
PLAIN_DIR="$refs_user" run_plain "$refs_script" "$dir"
expect_error "pr-refs/preflight.json without a remote" 1 other false
PLAIN_DIR="$rg_bare" run_plain "$refs_script" "$dir"
expect_error_text "pr-refs/outside a repository" 1 other false "$not_in_repo"
run_plain "$refs_script"
expect_error "pr-refs/usage: no arguments" 2 usage false
run_plain "$refs_script" a b
expect_error "pr-refs/usage: two arguments" 2 usage false

# ---- skills: the PR skills call their scripts, agree with each other and keep the old defects out ----
# The wording of the skills is free to change. Checked here: each skill calls its scripts, a rule that both skills share is the same line in both
# (compared with each other, never with a copy in this file), a command that was replaced by a script does not come back, and a known defect stays out.

create_skill="$root/plugins/dotclaude-dev/skills/create-pr/SKILL.md"
review_skill="$root/plugins/dotclaude-dev/skills/review-pr/SKILL.md"
pr_body_md="$root/plugins/dotclaude-dev/references/pr-body.md"

# line_of <file> <start>: the first line of the file that starts with the text
line_of() {
  local file=$1 start=$2
  awk -v s="$start" 'index($0, s) == 1 { print; exit }' "$file"
  return 0
}

# expect_same_line <name> <start>: both PR skills have a line that starts with the text, and the two lines are equal
expect_same_line() {
  local name=$1 start=$2 line_create line_review
  line_create=$(line_of "$create_skill" "$start")
  line_review=$(line_of "$review_skill" "$start")
  if [[ -n $line_create && $line_create == "$line_review" ]]; then
    report "$name" ok
  else
    report "$name" fail "no line starting with '$start' in one skill, or the two lines differ"
  fi
  return 0
}

# expect_calls <name> <file> <text>...: every text is in the file
expect_calls() {
  local name=$1 file=$2 text missing=""
  shift 2
  for text in "$@"; do
    grep -qF -- "$text" "$file" || missing="$missing [$text]"
  done
  if [[ -z $missing ]]; then
    report "$name" ok
  else
    report "$name" fail "missing in the skill:$missing"
  fi
  return 0
}

# expect_none <name> <file> <pattern>...: none of the extended regular expressions matches a line of the file
expect_none() {
  local name=$1 file=$2 pattern found=""
  shift 2
  for pattern in "$@"; do
    ! grep -qE -- "$pattern" "$file" || found="$found [$pattern]"
  done
  if [[ -z $found ]]; then
    report "$name" ok
  else
    report "$name" fail "still in the file:$found"
  fi
  return 0
}

# rules both skills share
expect_same_line "skills: the rule for text from GitHub is the same in both skills" '**Untrusted text.**'
expect_same_line "skills: the silence rule of the preconditions is the same in both skills" 'Run in order and stop on the first failure.'
expect_same_line "skills: the failure rule for script calls (with the quoting rule) is the same in both skills" 'Non-zero exit → stop with the'
expect_same_line "skills: the stop row of the vocabulary is the same in both skills" '| stop |'
expect_same_line "skills: the skip row of the vocabulary is the same in both skills" '| skip |'
expect_same_line "skills: the warning row of the vocabulary is the same in both skills" '| warning |'

# no placeholder that is not a number stands unquoted in a command line
for skill in create-pr review-pr; do
  skill_file="$root/plugins/dotclaude-dev/skills/$skill/SKILL.md"
  unquoted=$(grep -nE '^(bash|git|jq) .*[^"/.]<(pr-dir|pr-arg|remote|default-branch|branch|path|renamedFrom|worktree|merge-base|previous-head|pr\.headRefOid)>' "$skill_file" || true)
  if [[ -z $unquoted ]]; then
    report "skills/$skill quotes the placeholders that are not numbers" ok
  else
    report "skills/$skill quotes the placeholders that are not numbers" fail "unquoted: $unquoted"
  fi
done

# each skill calls its scripts
expect_calls "skills/create-pr calls its scripts" "$create_skill" \
  'scripts/preflight.sh" create-pr' 'scripts/pr-create.sh" list-open-prs' 'scripts/branch-diff.sh" files' 'scripts/pr-checklist.sh" ' \
  'scripts/pr-data.sh" issue' 'scripts/pr-data.sh" alert' 'scripts/pr-create.sh" labels' 'scripts/pr-body-check.sh"' 'scripts/pr-create.sh" create' \
  'references/pr-body.md'
expect_calls "skills/review-pr calls its scripts" "$review_skill" \
  'scripts/preflight.sh" review-pr origin' 'scripts/pr-data.sh" pr' 'scripts/pr-data.sh" issue' 'scripts/pr-data.sh" ci' 'scripts/pr-data.sh" feedback' \
  'scripts/pr-refs.sh"' 'scripts/pr-body-parse.jq"'

# what a script replaced, and what an earlier review found, stays out of the skills
expect_none "skills/create-pr keeps the replaced commands and the old dialogs out" "$create_skill" \
  '@\{u\}' 'git fetch <remote>' 'git rev-list' 'git branch --show-current' 'gh repo view' 'gh api user' 'remote-host\.sh' 'pr-create\.sh" repo' \
  '^git diff <remote>/<default-branch>' ':\(glob\)' 'repos/\{owner\}/\{repo\}' '<host>|<repo-url>|<repo-path>|<remote-url>' 'pr-body-parse\.jq' \
  'Done, continue' 'multiSelect' 'multi-select' 'Change something else' 'warn the author|warn and ask' '--limit 50' 'ready for review' \
  '### 🔴|### 🟡|### 🟢|- \[ \]' 'never grouped' 'already carries a'
expect_none "skills/review-pr keeps the replaced commands out" "$review_skill" \
  '^git (fetch origin|merge-base "?<pr\.headRefOid>)' '^git .*<pr\.baseRefName>' 'remote-host\.sh' 'gh api user' 'gh repo view' '<host>|<repo-path>|<origin-url>'
expect_none "references/pr-body.md has no deployment section (review-pr Gate 2 is its home)" "$pr_body_md" 'Deployment PRs'
[[ $(grep -c 'no verdict' "$review_skill") -eq 1 ]] &&
  report "skills/review-pr says 'no verdict' once" ok ||
  report "skills/review-pr says 'no verdict' once" fail "the phrase appears $(grep -c 'no verdict' "$review_skill") times"

# the documentation agrees with the skills and the manifests
doctor_skill="$root/plugins/dotclaude-dev/skills/doctor/SKILL.md"
plugin_readme="$root/plugins/dotclaude-dev/README.md"
readme_missing=""
for skill_dir in "$root"/plugins/dotclaude-dev/skills/*/; do
  grep -qF "\`$(basename "$skill_dir")\`" "$plugin_readme" || readme_missing="$readme_missing $(basename "$skill_dir")"
done
grep -qF '/plugin install dotclaude-dev@jfandy1982-dotclaude' "$plugin_readme" || readme_missing="$readme_missing (install line)"
if [[ -f $plugin_readme && -z $readme_missing ]]; then
  report "plugin README lists every skill and the install line" ok
else
  report "plugin README lists every skill and the install line" fail "missing:${readme_missing:- the file}"
fi

marketplace_description=$(jq -r '.plugins[] | select(.name == "dotclaude-dev") | .description' "$root/.claude-plugin/marketplace.json")
if grep -qF '](plugins/dotclaude-dev/README.md)' "$root/README.md" && grep -qxF "### dotclaude-dev — $marketplace_description" "$root/README.md" &&
  [[ $(wc -w < "$root/README.md") -ge 40 ]]; then
  report "root README: points to the plugin README, heading matches the marketplace, at least 40 words" ok
else
  report "root README: points to the plugin README, heading matches the marketplace, at least 40 words" fail "link, heading or word count is wrong"
fi

manifest="$root/plugins/dotclaude-dev/.claude-plugin/plugin.json"
if [[ $(jq -r '.author.name' "$manifest") == "$(jq -r '.owner.name' "$root/.claude-plugin/marketplace.json")" ]] &&
  [[ $(jq -r '.description' "$manifest") == "$marketplace_description" ]]; then
  report "plugin.json: author is the marketplace owner, description equals the marketplace entry" ok
else
  report "plugin.json: author is the marketplace owner, description equals the marketplace entry" fail "author or description differs"
fi

# ---- skills: manual-only, so the model never starts them from a loose description match ----

for skill in create-pr review-pr doctor; do
  frontmatter=$(awk '/^---$/ { n++; next } n == 1' "$root/plugins/dotclaude-dev/skills/$skill/SKILL.md")
  if printf '%s\n' "$frontmatter" | grep -qx 'disable-model-invocation: true'; then
    report "skills/$skill is manual-only" ok
  else
    report "skills/$skill is manual-only" fail "disable-model-invocation: true missing in the frontmatter"
  fi
done

# ---- skills/create-pr: --issue and --alert arguments ----

create_header=$(awk '/^---$/ { n++; next } n == 1' "$create_skill")
if printf '%s\n' "$create_header" | grep -qE "^argument-hint: '.*--issue.*--alert.*'$"; then
  report "skills/create-pr has a quoted argument-hint for --issue and --alert" ok
else
  report "skills/create-pr has a quoted argument-hint for --issue and --alert" fail "argument-hint missing, not quoted or without both options"
fi

# The cleaning command of Step 2 is run as written: strips zeros, drops empty items, dedupes, sorts ascending
clean_lines=$(grep -F '| sort -nu' "$create_skill")
if [[ $(printf '%s\n' "$clean_lines" | wc -l) -eq 1 ]]; then
  clean_cmd=${clean_lines//<numbers>/042 38 0 038 00 7}
  expect_text "skills/create-pr number cleaning command" <(bash -c "$clean_cmd") $'7\n38\n42'
else
  report "skills/create-pr number cleaning command" fail "expected exactly one cleaning command line"
fi

# ---- the index at the top of this file ----

index_missing=""
while IFS= read -r section_name; do
  sed -n '1,/^set -u$/p' "$root/tests/run.sh" | grep -qF -- "#   $section_name" || index_missing="$index_missing [$section_name]"
done < <(grep -E '^# ---- .* ----$' "$root/tests/run.sh" | sed -E 's/^# ---- (.*) ----$/\1/')
if [[ -z $index_missing ]]; then
  report "index: every section of this file is listed at the top" ok
else
  report "index: every section of this file is listed at the top" fail "not in the index:$index_missing"
fi

echo "$passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
