#!/usr/bin/env bash
# Runs the script tests of plugins/dotclaude-dev/scripts. Usage: bash tests/run.sh
# Portable to bash 3.2 and BSD tools (macOS): no GNU-only options.
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
parser="$root/plugins/dotclaude-dev/scripts/pr-body-parse.jq"
script="$root/plugins/dotclaude-dev/scripts/pr-data.sh"
fixtures="$root/tests/fixtures"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/dotclaude-tests-XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
passed=0
failed=0
SEED_PR_JSON=""

# The fake gh replaces the real one in every bash process started below
source "$root/tests/stub/gh.sh"
export -f gh

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

# expect_empty <name> <dir>: a failed run leaves no file behind
expect_empty() {
  local name=$1 dir=$2 listing
  listing=$(ls -A "$dir")
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

# new_stub: a fresh folder of canned answers for the fake gh
new_stub() {
  mktemp -d "$tmp/stub-XXXXXX"
  return $?
}

# fail_stub <stub-dir> <command> <exit-code> <stderr-text> [stdout-text]
fail_stub() {
  local dir=$1 name=$2 code=$3 text=$4 body=${5:-}
  printf '%s\n' "$text" > "$dir/$name.err"
  printf '%s\n' "$code" > "$dir/$name.exit"
  [[ $# -lt 5 ]] || printf '%s\n' "$body" > "$dir/$name.out"
  return 0
}

# run_data <stub-dir> <arguments...>: runs pr-data.sh with the fake gh; the word PR_DIR in the arguments becomes a fresh folder,
# which holds a pr.json copied from SEED_PR_JSON when that is set
run_data() {
  local stub=$1 arg
  local -a args=()
  shift
  PR_DIR=$(mktemp -d "$tmp/work-XXXXXX")
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

# pr_variant <name> <jq-edit-of-the-base-pr> <jq-check-on-pr.json>
pr_variant() {
  local name=$1 edit=$2 expr=$3 stub
  stub=$(new_stub)
  jq "$edit" "$fixtures/gh/pr-base.json" > "$stub/pr-view.out"
  cp "$fixtures/gh/pulls.json" "$stub/api.out"
  run_data "$stub" pr github.example.local https://github.example.local/o/r 7 PR_DIR
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
cp "$fixtures/gh/pulls.json" "$stub/api.out"
run_data "$stub" pr github.example.local https://github.example.local/o/r 7 PR_DIR
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
cp "$fixtures/gh/pulls.json" "$stub/api.out"
run_data "$stub" pr github.example.local https://github.example.local/o/r 7 PR_DIR
if grep -q 'repos/x/y/pulls/7' "$stub/calls.log"; then
  report "pr/base commit is read from the repository of the PR URL" ok
else
  report "pr/base commit is read from the repository of the PR URL" fail "$(cat "$stub/calls.log")"
fi

stub=$(new_stub)
jq '.body = null' "$fixtures/gh/pr-base.json" > "$stub/pr-view.out"
cp "$fixtures/gh/pulls.json" "$stub/api.out"
run_data "$stub" pr github.example.local https://github.example.local/o/r 7 PR_DIR
expect_text "pr/null body gives an empty body.txt" "$PR_DIR/body.txt" ""

# ---- pr-data.sh: issue, ci, feedback ----

stub=$(new_stub)
printf '%s\n' '{"number":12,"title":"Sample","state":"OPEN","body":"b","labels":[]}' > "$stub/issue-view.out"
run_data "$stub" issue github.example.local https://github.example.local/o/r 12 PR_DIR
expect_text "issue/stdout" "$tmp/data.out" "#12 Sample (OPEN)"
check "issue/issue-12.json" "$PR_DIR/issue-12.json" "$stub/issue-view.out"

# alert: the reduced file and the printed line
stub=$(new_stub)
cp "$fixtures/gh/alert-open.json" "$stub/api.out"
run_data "$stub" alert github.example.local o/r 3 PR_DIR
expect_text "alert/stdout" "$tmp/data.out" "#3 js/sql-injection (open)"
check "alert/alert-3.json is the reduced object" "$PR_DIR/alert-3.json" "$fixtures/gh/alert-expected.json"
expect_call "alert/asks the code scanning API of the repository" "$stub" "api --hostname github.example.local repos/o/r/code-scanning/alerts/3"

for st_n in fixed:4 dismissed:5; do
  st=${st_n%%:*}
  n=${st_n##*:}
  stub=$(new_stub)
  cp "$fixtures/gh/alert-$st.json" "$stub/api.out"
  run_data "$stub" alert github.example.local o/r "$n" PR_DIR
  expect_text "alert/state $st is printed" "$tmp/data.out" "#$n js/sql-injection ($st)"
done

stub=$(new_stub)
jq '.state = "auto_dismissed"' "$fixtures/gh/alert-open.json" > "$stub/api.out"
run_data "$stub" alert github.example.local o/r 3 PR_DIR
expect_text "alert/an unexpected state passes through" "$tmp/data.out" "#3 js/sql-injection (auto_dismissed)"

stub=$(new_stub)
cp "$fixtures/gh/alert-no-severity.json" "$stub/api.out"
run_data "$stub" alert github.example.local o/r 3 PR_DIR
if jq -e '.severity == null and .ruleId == "js/unused-local"' "$PR_DIR/alert-3.json" > /dev/null 2>&1; then
  report "alert/no severity stays null" ok
else
  report "alert/no severity stays null" fail "$(cat "$PR_DIR/alert-3.json" 2> /dev/null)"
fi

stub=$(new_stub)
cp "$fixtures/gh/alert-no-instance.json" "$stub/api.out"
run_data "$stub" alert github.example.local o/r 3 PR_DIR
if jq -e '.message == null and .path == null' "$PR_DIR/alert-3.json" > /dev/null 2>&1; then
  report "alert/no instance gives null message and path" ok
else
  report "alert/no instance gives null message and path" fail "$(cat "$PR_DIR/alert-3.json" 2> /dev/null)"
fi
expect_text "alert/no instance still prints the line" "$tmp/data.out" "#3 js/sql-injection (open)"

stub=$(new_stub)
jq '.most_recent_instance.message.text = "quote \" backslash \\ and\nnew line"' "$fixtures/gh/alert-open.json" > "$stub/api.out"
run_data "$stub" alert github.example.local o/r 3 PR_DIR
if jq -e '.message == "quote \" backslash \\ and\nnew line"' "$PR_DIR/alert-3.json" > /dev/null 2>&1; then
  report "alert/a message with quotes, backslash and newline stays intact" ok
else
  report "alert/a message with quotes, backslash and newline stays intact" fail "$(cat "$PR_DIR/alert-3.json" 2> /dev/null)"
fi

stub=$(new_stub)
fail_stub "$stub" api 1 "gh: Not Found (HTTP 404)" '{"message":"Not Found"}'
run_data "$stub" alert github.example.local o/r 9 PR_DIR
expect_error "alert/not found" 11 not_found false
expect_empty "alert/not found writes no file" "$PR_DIR"

stub=$(new_stub)
fail_stub "$stub" api 1 "Advanced Security must be enabled for this repository to use code scanning. (HTTP 403)" '{"message":"Advanced Security must be enabled"}'
run_data "$stub" alert github.example.local o/r 3 PR_DIR
expect_error "alert/code scanning not enabled is not_found, no body on stdout" 11 not_found false
expect_empty "alert/code scanning not enabled writes no file" "$PR_DIR"

stub=$(new_stub)
printf '%s\n' 'not json' > "$stub/api.out"
run_data "$stub" alert github.example.local o/r 3 PR_DIR
expect_error "alert/unreadable response" 1 other false
expect_empty "alert/unreadable response writes no file" "$PR_DIR"

for body in 'null' '{"most_recent_instance":null}' '{"number":"x"}' ''; do
  stub=$(new_stub)
  printf '%s' "$body" > "$stub/api.out"
  run_data "$stub" alert github.example.local o/r 3 PR_DIR
  expect_error "alert/a response that is not an alert is an error: ${body:-empty}" 1 other false
  expect_empty "alert/a response that is not an alert writes no file: ${body:-empty}" "$PR_DIR"
done

run_data "$stub" alert github.example.local o/r abc PR_DIR
expect_error "usage/alert number is not a number" 2 usage false
run_data "$stub" alert github.example.local o/r 3
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
cp "$fixtures/gh/feedback-inline-pages.txt" "$stub/api.out"
SEED_PR_JSON="$fixtures/gh/feedback-view.json"
run_data "$stub" feedback github.example.local o/r 7 PR_DIR
SEED_PR_JSON=""
check "feedback/feedback.json" "$PR_DIR/feedback.json" "$fixtures/gh/feedback-expected.json"
expect_text "feedback/counts" "$tmp/data.out" "1 comments, 1 reviews, 2 inline comments"
if grep -q -- '--paginate' "$stub/calls.log"; then
  report "feedback/asks gh for all pages" ok
else
  report "feedback/asks gh for all pages" fail "$(cat "$stub/calls.log")"
fi

stub=$(new_stub)
printf '%s\n' '[]' > "$stub/api.out"
printf '%s\n' '{"comments":[],"reviews":[]}' > "$tmp/no-comments.json"
SEED_PR_JSON="$tmp/no-comments.json"
run_data "$stub" feedback github.example.local o/r 7 PR_DIR
SEED_PR_JSON=""
expect_text "feedback/no comments at all" "$tmp/data.out" "0 comments, 0 reviews, 0 inline comments"

# ---- error contract (contract.sh) ----
# Every error class, tested once through the pr subcommand of pr-data.sh; pr-create.sh gets the same code by sourcing the file.
# The stub also prints an error body on stdout, which must not leak.

while IFS='|' read -r label gh_exit stderr_text want_exit error retryable; do
  stub=$(new_stub)
  fail_stub "$stub" pr-view "$gh_exit" "$stderr_text" '{"message":"error body"}'
  run_data "$stub" pr github.example.local https://github.example.local/o/r 7 PR_DIR
  expect_error "contract/$label" "$want_exit" "$error" "$retryable"
  expect_empty "contract/$label leaves no file" "$PR_DIR"
done << 'EOF'
auth by gh exit code 4|4|authentication required|10|auth|false
auth by HTTP 401|1|gh: Bad credentials (HTTP 401)|10|auth|false
not found, GraphQL|1|GraphQL: Could not resolve to a PullRequest with the number of 9. (repository.pullRequest)|11|not_found|false
not found, HTTP 404|1|gh: Not Found (HTTP 404)|11|not_found|false
forbidden without rate limit|1|gh: Forbidden (HTTP 403)|11|not_found|false
rate limit|1|gh: API rate limit exceeded (HTTP 403)|12|rate_limited|true
network|1|error connecting to github.example.local|13|network|true
unknown error|1|something odd happened|1|other|false
EOF

jq -e '.message | contains("something odd happened")' "$tmp/data.err" > /dev/null &&
  report "pr/unknown error shows the first line of gh" ok ||
  report "pr/unknown error shows the first line of gh" fail "$(cat "$tmp/data.err")"

# the PR was read, the base commit call fails: nothing is written
stub=$(new_stub)
cp "$fixtures/gh/pr-base.json" "$stub/pr-view.out"
fail_stub "$stub" api 1 "gh: Not Found (HTTP 404)" '{"message":"Not Found"}'
run_data "$stub" pr github.example.local https://github.example.local/o/r 7 PR_DIR
expect_error "pr/base commit call fails" 11 not_found false
expect_empty "pr/base commit call fails leaves no file" "$PR_DIR"

stub=$(new_stub)
fail_stub "$stub" api 1 "error connecting to github.example.local"
cp "$fixtures/gh/pr-base.json" "$stub/pr-view.out"
run_data "$stub" pr github.example.local https://github.example.local/o/r 7 PR_DIR
expect_error "pr/network error on the base commit call" 13 network true

stub=$(new_stub)
fail_stub "$stub" issue-view 1 "GraphQL: Could not resolve to an Issue with the number of 9."
run_data "$stub" issue github.example.local https://github.example.local/o/r 9 PR_DIR
expect_error "issue/not found" 11 not_found false

# the offline subcommands need the pr.json that pr wrote
stub=$(new_stub)
run_data "$stub" ci PR_DIR
expect_error "ci/no pr.json" 1 other false
run_data "$stub" feedback github.example.local o/r 7 PR_DIR
expect_error "feedback/no pr.json" 1 other false

# The page fetch fails and jq on empty input would accept it: must still fail, with no feedback file
stub=$(new_stub)
fail_stub "$stub" api 1 "gh: Not Found (HTTP 404)" '{"message":"Not Found"}'
SEED_PR_JSON="$fixtures/gh/feedback-view.json"
run_data "$stub" feedback github.example.local o/r 7 PR_DIR
SEED_PR_JSON=""
expect_error "feedback/page fetch fails" 11 not_found false
expect_absent "feedback/page fetch fails leaves no feedback.json" "$PR_DIR/feedback.json"

stub=$(new_stub)
run_data "$stub" pr github.example.local
expect_error "usage/too few arguments" 2 usage false
run_data "$stub" issue github.example.local https://github.example.local/o/r abc PR_DIR
expect_error "usage/issue number is not a number" 2 usage false
run_data "$stub" feedback github.example.local o/r abc PR_DIR
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

# ---- pr-create.sh ----

create_script="$root/plugins/dotclaude-dev/scripts/pr-create.sh"
repo_url=https://github.example.local/o/r

stub=$(new_stub)
printf '%s\n' '{"url":"https://github.example.local/o/r","nameWithOwner":"o/r","defaultBranchRef":{"name":"main"}}' > "$stub/repo-view.out"
run_stub "$stub" "$create_script" repo github.example.local git@github.example.local:o/r.git
printf '%s\n' '{"url":"https://github.example.local/o/r","path":"o/r","defaultBranch":"main"}' > "$tmp/create-expected.json"
check "repo/prints url, path and default branch" "$tmp/data.out" "$tmp/create-expected.json"
expect_call "repo/asks about the remote URL" "$stub" "repo view git@github.example.local:o/r.git"

stub=$(new_stub)
printf '%s\n' '[{"name":"type: bug","description":"Bug"},{"name":"aspect: ui","description":"UI"},{"name":"priority: high","description":"x"}]' > "$stub/label-list.out"
work=$(mktemp -d "$tmp/work-XXXXXX")
run_stub "$stub" "$create_script" labels github.example.local "$repo_url" "$work"
printf '%s\n' '{"mode":"taxonomy","labels":[{"name":"type: bug","description":"Bug"},{"name":"aspect: ui","description":"UI"}]}' > "$tmp/create-expected.json"
check "labels/taxonomy mode keeps type: and aspect: labels" "$tmp/data.out" "$tmp/create-expected.json"
check "labels/labels.json holds all labels" "$work/labels.json" "$stub/label-list.out"
expect_call "labels/limit and repository are passed" "$stub" "label list --repo $repo_url --json name,description --limit 50"

stub=$(new_stub)
printf '%s\n' '[{"name":"bug","description":"b"},{"name":"help wanted","description":""}]' > "$stub/label-list.out"
work=$(mktemp -d "$tmp/work-XXXXXX")
run_stub "$stub" "$create_script" labels github.example.local "$repo_url" "$work"
jq -c '{mode: "fallback", labels: .}' "$stub/label-list.out" > "$tmp/create-expected.json"
check "labels/fallback mode without type: or aspect: labels" "$tmp/data.out" "$tmp/create-expected.json"

stub=$(new_stub)
printf '%s\n' '[]' > "$stub/pr-list.out"
run_stub "$stub" "$create_script" open-pr github.example.local "$repo_url" feat/x
expect_text "open-pr/none" "$tmp/data.out" "[]"
expect_call "open-pr/asks for the branch and open PRs" "$stub" "pr list --repo $repo_url --head feat/x --state open"

# create: title and body come from files and reach gh unchanged
title='fix: quote `$TMPDIR` in "paths" $(echo x)'
stub=$(new_stub)
printf '%s\n' 'https://github.example.local/o/r/pull/9' > "$stub/pr-create.out"
work=$(mktemp -d "$tmp/work-XXXXXX")
printf '%s\n' "$title" > "$work/title.txt"
printf '%s\n' 'body text' > "$work/body.txt"
run_stub "$stub" "$create_script" create github.example.local "$repo_url" "$work" no "type: bug" "aspect: ui"
expect_text "create/stdout is only the URL" "$tmp/data.out" "https://github.example.local/o/r/pull/9"
expect_call "create/repository, assignee, title and body file" "$stub" "pr create --repo $repo_url --assignee @me --title $title --body-file $work/body.txt"
expect_call "create/several labels" "$stub" "--label type: bug --label aspect: ui"
expect_no_call "create/no draft flag for no" "$stub" "--draft"

stub=$(new_stub)
run_stub "$stub" "$create_script" create github.example.local "$repo_url" "$work" yes "type: bug"
expect_call "create/draft with one label" "$stub" "--body-file $work/body.txt --draft --label type: bug"
stub=$(new_stub)
run_stub "$stub" "$create_script" create github.example.local "$repo_url" "$work" no
expect_no_call "create/no label flag without labels" "$stub" "--label"

stub=$(new_stub)
fail_stub "$stub" pr-create 1 "error connecting to github.example.local"
run_stub "$stub" "$create_script" create github.example.local "$repo_url" "$work" no
expect_error "create/gh fails" 13 network true
jq -e '.message | startswith("Could not create the PR")' "$tmp/data.err" > /dev/null &&
  report "create/failure message says create" ok ||
  report "create/failure message says create" fail "$(cat "$tmp/data.err")"

stub=$(new_stub)
work=$(mktemp -d "$tmp/work-XXXXXX")
printf '%s\n' 'body text' > "$work/body.txt"
run_stub "$stub" "$create_script" create github.example.local "$repo_url" "$work" no
expect_error "create/title file missing" 1 other false
printf '%s\n' '' > "$work/title.txt"
run_stub "$stub" "$create_script" create github.example.local "$repo_url" "$work" no
expect_error "create/empty title" 1 other false
work=$(mktemp -d "$tmp/work-XXXXXX")
printf '%s\n' 'a title' > "$work/title.txt"
run_stub "$stub" "$create_script" create github.example.local "$repo_url" "$work" no
expect_error "create/body file missing" 1 other false

run_stub "$stub" "$create_script" create github.example.local "$repo_url" "$work" maybe
expect_error "usage/create draft is not yes or no" 2 usage false
run_stub "$stub" "$create_script" bogus
expect_error "usage/pr-create unknown subcommand" 2 usage false

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

rg_lone=$(mktemp -d "$tmp/lone-XXXXXX")
make_lone_repo "$rg_lone"
rg_dir=$(mktemp -d "$tmp/folder-XXXXXX")
# git's messages are translated: LC_ALL=C makes the text comparable
LC_ALL=C PLAIN_DIR="$rg_lone" run_plain "$checklist_script" origin main
expect_error "run_git/pr-checklist: no merge base is one error line" 1 other false
expect_error_message "run_git/pr-checklist: the message carries git's reason" "no merge base"
LC_ALL=C PLAIN_DIR="$rg_lone" run_plain "$diff_script" files origin main "$rg_dir"
expect_error "run_git/branch-diff files: no merge base is one error line" 1 other false
expect_error_message "run_git/branch-diff files: the message carries git's reason" "no merge base"

rg_bare=$(mktemp -d "$tmp/bare-XXXXXX")
LC_ALL=C PLAIN_DIR="$rg_bare" run_plain "$checklist_script" origin main
expect_error "run_git/pr-checklist: outside a repository" 1 other false
expect_error_message "run_git/pr-checklist: outside a repository, git's reason" "not a git repository"
LC_ALL=C PLAIN_DIR="$rg_bare" run_plain "$diff_script" files origin main "$rg_dir"
expect_error "run_git/branch-diff files: outside a repository" 1 other false
expect_error_message "run_git/branch-diff files: outside a repository, git's reason" "not a git repository"

# ---- skills: the failure rule for script calls is worded the same ----

rule='Non-zero exit → stop with the `message` of the JSON line the script wrote to stderr, unless a step says otherwise. This holds for every script call in this skill. A stderr without such a line is shown as it is.'
for skill in create-pr review-pr; do
  if grep -qF -- "$rule" "$root/plugins/dotclaude-dev/skills/$skill/SKILL.md"; then
    report "skills/$skill states the failure rule" ok
  else
    report "skills/$skill states the failure rule" fail "sentence not found"
  fi
done

# Step 1 gets the diff from the script, not from raw git diff commands
create_skill="$root/plugins/dotclaude-dev/skills/create-pr/SKILL.md"
if grep -qF 'scripts/branch-diff.sh" files' "$create_skill" && ! grep -qE '^git diff <remote>/<default-branch>\.\.\.HEAD( --name-only)?$' "$create_skill"; then
  report "skills/create-pr Step 1 uses branch-diff.sh" ok
else
  report "skills/create-pr Step 1 uses branch-diff.sh" fail "script call missing or a raw git diff line is left"
fi

# Step 1 gets the checklist from the script
if grep -qF 'scripts/pr-checklist.sh" ' "$create_skill" && ! grep -qF ':(glob)' "$create_skill"; then
  report "skills/create-pr Step 1 uses pr-checklist.sh" ok
else
  report "skills/create-pr Step 1 uses pr-checklist.sh" fail "script call missing or :(glob) is left"
fi

# Step 3 gets the alert from the script
if grep -qF 'scripts/pr-data.sh" alert' "$create_skill" && ! grep -qF 'repos/{owner}/{repo}' "$create_skill"; then
  report "skills/create-pr Step 3 uses pr-data.sh alert" ok
else
  report "skills/create-pr Step 3 uses pr-data.sh alert" fail "script call missing or repos/{owner}/{repo} is left"
fi

echo "$passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
