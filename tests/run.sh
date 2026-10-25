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
  run_data "$stub" pr github.com https://github.com/o/r 7 PR_DIR
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

# ---- pr-data.sh: pr and refs ----

stub=$(new_stub)
cp "$fixtures/gh/pr-base.json" "$stub/pr-view.out"
cp "$fixtures/gh/pulls.json" "$stub/api.out"
run_data "$stub" pr github.com https://github.com/o/r 7 PR_DIR
check "pr/pr.json" "$PR_DIR/pr.json" "$fixtures/gh/pr-ok.json"
jq 'del(.body, .files, .comments, .reviews, .statusCheckRollup)' "$fixtures/gh/pr-ok.json" > "$tmp/expected-stdout.json"
check "pr/stdout leaves out the bulky fields" "$tmp/data.out" "$tmp/expected-stdout.json"
expect_text "pr/body.txt" "$PR_DIR/body.txt" "$(jq -r '.body' "$fixtures/gh/pr-base.json")"

pr_variant "sameRepo is false for another repository" '.url = "https://github.com/x/y/pull/7"' '.sameRepo == false'
pr_variant "sameRepo ignores letter case" '.url = "https://github.com/O/R/pull/7"' '.sameRepo == true'
pr_variant "isDeployment is true for the deployment label" '.labels = [{"name": "type: deployment"}]' '.isDeployment == true'
pr_variant "isDeployment is false without labels" '.labels = []' '.isDeployment == false'
pr_variant "base commit comes from the REST answer" '.' '.baseRefOid == "base123"'

# a PR URL of another repository: the base commit is read from that repository, not from --repo
stub=$(new_stub)
jq '.url = "https://github.com/x/y/pull/7"' "$fixtures/gh/pr-base.json" > "$stub/pr-view.out"
cp "$fixtures/gh/pulls.json" "$stub/api.out"
run_data "$stub" pr github.com https://github.com/o/r 7 PR_DIR
if grep -q 'repos/x/y/pulls/7' "$stub/calls.log"; then
  report "pr/base commit is read from the repository of the PR URL" ok
else
  report "pr/base commit is read from the repository of the PR URL" fail "$(cat "$stub/calls.log")"
fi

stub=$(new_stub)
jq '.body = null' "$fixtures/gh/pr-base.json" > "$stub/pr-view.out"
cp "$fixtures/gh/pulls.json" "$stub/api.out"
run_data "$stub" pr github.com https://github.com/o/r 7 PR_DIR
expect_text "pr/null body gives an empty body.txt" "$PR_DIR/body.txt" ""

# ---- pr-data.sh: issue, ci, feedback ----

stub=$(new_stub)
printf '%s\n' '{"number":12,"title":"Sample","state":"OPEN","body":"b","labels":[]}' > "$stub/issue-view.out"
run_data "$stub" issue github.com https://github.com/o/r 12 PR_DIR
expect_text "issue/stdout" "$tmp/data.out" "#12 Sample (OPEN)"
check "issue/issue-12.json" "$PR_DIR/issue-12.json" "$stub/issue-view.out"

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
run_data "$stub" feedback github.com o/r 7 PR_DIR
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
run_data "$stub" feedback github.com o/r 7 PR_DIR
SEED_PR_JSON=""
expect_text "feedback/no comments at all" "$tmp/data.out" "0 comments, 0 reviews, 0 inline comments"

# ---- pr-data.sh: errors ----
# Every error class through the pr subcommand. The stub also prints an error body on stdout, which must not leak.

while IFS='|' read -r label gh_exit stderr_text want_exit error retryable; do
  stub=$(new_stub)
  fail_stub "$stub" pr-view "$gh_exit" "$stderr_text" '{"message":"error body"}'
  run_data "$stub" pr github.com https://github.com/o/r 7 PR_DIR
  expect_error "pr/$label" "$want_exit" "$error" "$retryable"
  expect_empty "pr/$label leaves no file" "$PR_DIR"
done << 'EOF'
auth by gh exit code 4|4|authentication required|10|auth|false
auth by HTTP 401|1|gh: Bad credentials (HTTP 401)|10|auth|false
not found, GraphQL|1|GraphQL: Could not resolve to a PullRequest with the number of 9. (repository.pullRequest)|11|not_found|false
not found, HTTP 404|1|gh: Not Found (HTTP 404)|11|not_found|false
forbidden without rate limit|1|gh: Forbidden (HTTP 403)|11|not_found|false
rate limit|1|gh: API rate limit exceeded (HTTP 403)|12|rate_limited|true
network|1|error connecting to api.github.com|13|network|true
unknown error|1|something odd happened|1|other|false
EOF

jq -e '.message | contains("something odd happened")' "$tmp/data.err" > /dev/null &&
  report "pr/unknown error shows the first line of gh" ok ||
  report "pr/unknown error shows the first line of gh" fail "$(cat "$tmp/data.err")"

# the PR was read, the base commit call fails: nothing is written
stub=$(new_stub)
cp "$fixtures/gh/pr-base.json" "$stub/pr-view.out"
fail_stub "$stub" api 1 "gh: Not Found (HTTP 404)" '{"message":"Not Found"}'
run_data "$stub" pr github.com https://github.com/o/r 7 PR_DIR
expect_error "pr/base commit call fails" 11 not_found false
expect_empty "pr/base commit call fails leaves no file" "$PR_DIR"

stub=$(new_stub)
fail_stub "$stub" api 1 "error connecting to api.github.com"
cp "$fixtures/gh/pr-base.json" "$stub/pr-view.out"
run_data "$stub" pr github.com https://github.com/o/r 7 PR_DIR
expect_error "pr/network error on the base commit call" 13 network true

stub=$(new_stub)
fail_stub "$stub" issue-view 1 "GraphQL: Could not resolve to an Issue with the number of 9."
run_data "$stub" issue github.com https://github.com/o/r 9 PR_DIR
expect_error "issue/not found" 11 not_found false

# the offline subcommands need the pr.json that pr wrote
stub=$(new_stub)
run_data "$stub" ci PR_DIR
expect_error "ci/no pr.json" 1 other false
run_data "$stub" feedback github.com o/r 7 PR_DIR
expect_error "feedback/no pr.json" 1 other false

# The page fetch fails and jq on empty input would accept it: must still fail, with no feedback file
stub=$(new_stub)
fail_stub "$stub" api 1 "gh: Not Found (HTTP 404)" '{"message":"Not Found"}'
SEED_PR_JSON="$fixtures/gh/feedback-view.json"
run_data "$stub" feedback github.com o/r 7 PR_DIR
SEED_PR_JSON=""
expect_error "feedback/page fetch fails" 11 not_found false
expect_absent "feedback/page fetch fails leaves no feedback.json" "$PR_DIR/feedback.json"

stub=$(new_stub)
run_data "$stub" pr github.com
expect_error "usage/too few arguments" 2 usage false
run_data "$stub" issue github.com https://github.com/o/r abc PR_DIR
expect_error "usage/issue number is not a number" 2 usage false
run_data "$stub" feedback github.com o/r abc PR_DIR
expect_error "usage/feedback number is not a number" 2 usage false
run_data "$stub" bogus
expect_error "usage/unknown subcommand" 2 usage false

echo "$passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
