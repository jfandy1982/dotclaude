#!/usr/bin/env bash
# GitHub reads of review-pr behind one error contract.
#   pr-data.sh pr <host> <repo-url> <pr-arg> <pr-dir>
#       one gh pr view with all PR fields (including CI rollup, comments, reviews) plus the base commit;
#       writes <pr-dir>/pr.json and <pr-dir>/body.txt, prints pr.json without the bulky fields
#   pr-data.sh issue <host> <repo-url> <issue-number> <pr-dir>
#       writes <pr-dir>/issue-<issue-number>.json, prints "#<number> <title> (<STATE>)"
#   pr-data.sh alert <host> <repo-path> <alert-number> <pr-dir>
#       one code scanning alert, reduced to {number, state, url, ruleId, ruleDescription, severity, message, path}
#       (missing parts null), written to <pr-dir>/alert-<alert-number>.json, prints "#<number> <ruleId> (<state>)"
#   pr-data.sh ci <pr-dir>
#       reads <pr-dir>/pr.json, prints {passed, failed, pending}
#   pr-data.sh feedback <host> <repo-path> <pr-number> <pr-dir>
#       reads comments and reviews from <pr-dir>/pr.json, fetches the inline comments,
#       writes <pr-dir>/feedback.json, prints the counts
# Errors follow the contract in contract.sh (one JSON line on stderr, fixed exit codes).
# Portable to bash 3.2 and BSD tools (macOS): no GNU-only options.
set -u -o pipefail

SCRIPT="pr-data.sh"
SUBCOMMANDS='pr|issue|alert|ci|feedback'
# shellcheck source=contract.sh
source "$(dirname "${BASH_SOURCE[0]}")/contract.sh"

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
  return $?
}

cmd_issue() {
  local host=$1 repo_url=$2 number=$3 dir=$4
  HOST=$host
  [[ $number =~ ^[0-9]+$ ]] || usage
  run_gh "issue #$number" issue view "$number" --repo "$repo_url" --json number,title,state,body,labels
  write_file "$dir" "issue-$number.json" "$OUT"
  printf '%s' "$OUT" | jq -r '"#\(.number) \(.title) (\(.state))"'
  return $?
}

cmd_alert() {
  local host=$1 repo_path=$2 number=$3 dir=$4 result
  HOST=$host
  [[ $number =~ ^[0-9]+$ ]] || usage
  run_gh "alert #$number" api --hostname "$host" "repos/$repo_path/code-scanning/alerts/$number"
  # -e with select: anything that is not an alert object with a numeric number gives no output, so the die below fires
  result=$(printf '%s' "$OUT" | jq -e 'select(type == "object" and (.number | type) == "number") | {
    number, state, url: .html_url,
    ruleId: .rule.id, ruleDescription: .rule.description, severity: .rule.security_severity_level,
    message: .most_recent_instance.message.text, path: .most_recent_instance.location.path}' 2> /dev/null) ||
    die "alert #$number" "Cannot read the alert returned by gh."
  write_file "$dir" "alert-$number.json" "$result"
  printf '%s' "$result" | jq -r '"#\(.number) \(.ruleId) (\(.state))"'
  return $?
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
  return 0
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
  return $?
}

main() {
  local cmd=${1:-}
  [[ $# -gt 0 ]] && shift
  case $cmd in
    pr) [[ $# -eq 4 ]] || usage; cmd_pr "$@" ;;
    issue) [[ $# -eq 4 ]] || usage; cmd_issue "$@" ;;
    alert) [[ $# -eq 4 ]] || usage; cmd_alert "$@" ;;
    ci) [[ $# -eq 1 ]] || usage; cmd_ci "$@" ;;
    feedback) [[ $# -eq 4 ]] || usage; cmd_feedback "$@" ;;
    *) usage ;;
  esac
  return $?
}

main "$@"
