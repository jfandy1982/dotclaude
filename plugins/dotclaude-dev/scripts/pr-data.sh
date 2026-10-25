#!/usr/bin/env bash
# GitHub reads of review-pr behind one error contract.
#   pr-data.sh pr <host> <repo-url> <pr-arg> <pr-dir>
#       one gh pr view with all PR fields (including CI rollup, comments, reviews) plus the base commit;
#       writes <pr-dir>/pr.json and <pr-dir>/body.txt, prints pr.json without the bulky fields
#   pr-data.sh issue <host> <repo-url> <issue-number> <pr-dir>
#       writes <pr-dir>/issue-<issue-number>.json, prints "#<number> <title> (<STATE>)"
#   pr-data.sh ci <pr-dir>
#       reads <pr-dir>/pr.json, prints {passed, failed, pending}
#   pr-data.sh feedback <host> <repo-path> <pr-number> <pr-dir>
#       reads comments and reviews from <pr-dir>/pr.json, fetches the inline comments,
#       writes <pr-dir>/feedback.json, prints the counts
# On failure: nothing on stdout, one JSON line on stderr {error, exit, retryable, what, message}
# and a fixed exit code: 10 auth, 11 not_found, 12 rate_limited, 13 network, 1 other, 2 usage.
# shortcut: the cause is matched from the text of gh's error output, replace by a structured status if gh offers one.
# Portable to bash 3.2 and BSD tools (macOS): no GNU-only options.
set -u -o pipefail

HOST=""
OUT=""

command -v jq > /dev/null 2>&1 || { echo "pr-data.sh: jq is required" >&2; exit 1; }
ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/dotclaude-pr-data-XXXXXX") || exit 1
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
}

usage() {
  emit_error usage 2 false "arguments" "Wrong arguments. Usage: pr-data.sh pr|issue|ci|feedback <arguments>, see the header of the script."
}

# fail <what> <gh-exit-code>: classify the captured gh error output and exit
fail() {
  local what=$1 code=$2 first
  first=$(head -n 1 "$ERR_FILE")
  if [[ $code -eq 4 ]] || grep -qiE 'HTTP 401|gh auth login' "$ERR_FILE"; then
    emit_error auth 10 false "$what" "Not authenticated with $HOST. Run \`gh auth login --hostname $HOST\`, then re-run."
  fi
  if grep -qi 'rate limit' "$ERR_FILE"; then
    emit_error rate_limited 12 true "$what" "Could not read $what: GitHub rate limit reached. Wait a few minutes, then re-run."
  fi
  if grep -qiE 'could not resolve to|no pull requests found|not found|HTTP 40[34]|HTTP 410' "$ERR_FILE"; then
    emit_error not_found 11 false "$what" "Could not read $what: not found, or you have no access. Check the number and your access to the repository, then re-run."
  fi
  if grep -qiE 'error connecting to|no such host|could not resolve host|timeout|dial tcp|connection refused' "$ERR_FILE"; then
    emit_error network 13 true "$what" "Could not read $what: cannot reach $HOST. Check the connection, then re-run."
  fi
  emit_error other 1 false "$what" "Could not read $what: ${first:-gh exited with code $code}."
}

# run_gh <what> <gh-arguments...>: stores stdout in OUT; a failed call never reaches the caller
run_gh() {
  local what=$1 code=0
  shift
  OUT=$(gh "$@" 2> "$ERR_FILE") || code=$?
  [[ $code -eq 0 ]] || fail "$what" "$code"
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

# require_pr_json <dir> <what>: the offline subcommands read what pr wrote
require_pr_json() {
  local dir=$1 what=$2
  [[ -f $dir/pr.json ]] || die "$what" "Folder $dir has no pr.json. Fetch the PR first."
  return 0
}

cmd_pr() {
  local host=$1 repo_url=$2 pr_arg=$3 dir=$4 json body repo_path number base
  HOST=$host
  run_gh "PR $pr_arg" pr view "$pr_arg" --repo "$repo_url" \
    --json number,url,title,body,labels,files,author,state,isDraft,isCrossRepository,baseRefName,headRefName,headRefOid,additions,deletions,changedFiles,statusCheckRollup,comments,reviews
  json=$OUT
  # the repository is taken from the PR's own URL: a PR URL makes gh read another repository than --repo
  repo_path=$(printf '%s' "$json" | jq -r '.url | capture("^https://[^/]+/(?<path>.+)/pull/[0-9]+$").path') ||
    die "PR $pr_arg" "Cannot read the PR URL returned by gh."
  number=$(printf '%s' "$json" | jq -r '.number') || die "PR $pr_arg" "Cannot read the PR number returned by gh."
  run_gh "base commit of PR #$number" api --hostname "$host" "repos/$repo_path/pulls/$number"
  base=$(printf '%s' "$OUT" | jq -r '.base.sha') || die "PR $pr_arg" "Cannot read the base commit returned by gh."
  json=$(printf '%s' "$json" | jq --arg repo "$repo_url" --arg base "$base" '. + {
    sameRepo:     ((.url | ascii_downcase) | startswith(($repo + "/pull/") | ascii_downcase)),
    isDeployment: any(.labels[]; .name == "type: deployment"),
    baseRefOid:   $base
  }') || die "PR $pr_arg" "Cannot read the PR data returned by gh."
  body=$(printf '%s' "$json" | jq -r '.body // ""') || die "PR $pr_arg" "Cannot read the PR body returned by gh."
  write_file "$dir" pr.json "$json"
  write_file "$dir" body.txt "$body"
  printf '%s' "$json" | jq 'del(.body, .files, .comments, .reviews, .statusCheckRollup)'
}

cmd_issue() {
  local host=$1 repo_url=$2 number=$3 dir=$4
  HOST=$host
  [[ $number =~ ^[0-9]+$ ]] || usage
  run_gh "issue #$number" issue view "$number" --repo "$repo_url" --json number,title,state,body,labels
  write_file "$dir" "issue-$number.json" "$OUT"
  printf '%s' "$OUT" | jq -r '"#\(.number) \(.title) (\(.state))"'
}

cmd_ci() {
  local dir=$1
  require_pr_json "$dir" "CI status"
  jq '
    [(.statusCheckRollup // [])[] | {name: (.name // .context),
       state: (if (.status // "COMPLETED") != "COMPLETED" or ((.conclusion // .state) | IN("PENDING", "EXPECTED")) then "pending"
               elif ((.conclusion // .state) | IN("SUCCESS", "SKIPPED", "NEUTRAL")) then "passed"
               else "failed" end)}]
    | {passed: (map(select(.state == "passed")) | length),
       failed: [.[] | select(.state == "failed") | .name],
       pending: [.[] | select(.state == "pending") | .name]}' "$dir/pr.json" ||
    die "CI status" "Cannot read the CI status in $dir/pr.json."
}

cmd_feedback() {
  local host=$1 repo_path=$2 number=$3 dir=$4 inline result
  HOST=$host
  [[ $number =~ ^[0-9]+$ ]] || usage
  require_pr_json "$dir" "prior feedback"
  # one JSON array per page; slurping joins them
  run_gh "inline comments of PR #$number" api --paginate --hostname "$host" "repos/$repo_path/pulls/$number/comments"
  inline=$(printf '%s' "$OUT" | jq -s 'add // []') || die "inline comments of PR #$number" "Cannot read the inline comments returned by gh."
  result=$(jq --argjson inline "$inline" '{
    discussion: {
      comments: [.comments[] | {author: .author.login, body}],
      reviews: [.reviews[] | select(.body != "") | {author: .author.login, state, body}]},
    inline: [$inline[] | {author: .user.login, path, line, body}]}' "$dir/pr.json") ||
    die "prior feedback" "Cannot read the comments in $dir/pr.json."
  write_file "$dir" feedback.json "$result"
  printf '%s' "$result" | jq -r '"\(.discussion.comments | length) comments, \(.discussion.reviews | length) reviews, \(.inline | length) inline comments"'
}

main() {
  local cmd=${1:-}
  [[ $# -gt 0 ]] && shift
  case $cmd in
    pr) [[ $# -eq 4 ]] || usage; cmd_pr "$@" ;;
    issue) [[ $# -eq 4 ]] || usage; cmd_issue "$@" ;;
    ci) [[ $# -eq 1 ]] || usage; cmd_ci "$@" ;;
    feedback) [[ $# -eq 4 ]] || usage; cmd_feedback "$@" ;;
    *) usage ;;
  esac
}

main "$@"
