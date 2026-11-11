#!/usr/bin/env bash
# The diff of the current branch against <remote>/<default-branch> (merge-base), in three levels for create-pr.
#   branch-diff.sh files <remote> <default-branch> <pr-dir>
#       one call per <pr-dir>: stops with an error when <pr-dir>/diff exists already (nothing is deleted);
#       writes <pr-dir>/diff/NNN.diff for every file that gets a diff (NNN = 001, 002, ... in git's file order) and prints
#       a one-line JSON array [{path, renamedFrom, added, removed, generated, diff}]:
#       added/removed are null for binary files, diff is the path of the diff file or null;
#       also leaves <pr-dir>/changed-files.list (git's NUL-separated numstat, read back by the script itself)
#   branch-diff.sh file <remote> <default-branch> <path> [<old-path>]
#       prints the diff of one path (nothing when the path did not change); pass renamedFrom as <old-path> for a renamed file
# Errors follow the contract in contract.sh (no gh call is made here).
# Portable to bash 3.2 and BSD tools (macOS): no GNU-only options.
set -u -o pipefail

SCRIPT="branch-diff.sh"
SUBCOMMANDS='files|file'
# shellcheck source=contract.sh
source "$(dirname "${BASH_SOURCE[0]}")/contract.sh"

# Lockfiles that are generated unless .gitattributes says otherwise; other lockfiles: mark them linguist-generated in the repository
LOCKFILES="package-lock.json yarn.lock pnpm-lock.yaml"

# file_diff <path> [<old-path>]: prints the diff of one path; ":(top,literal)" makes the path relative to the repository root and matches no glob.
# A renamed file needs both paths, otherwise git shows a delete plus an add.
# --no-color, --no-ext-diff and --no-textconv keep the user's git config out of the text the model reads.
# shortcut: one file's diff is read whole, so a huge unmarked file (minified bundle) can hit the tool output limit; mark it linguist-generated in .gitattributes
file_diff() {
  local path=$1 old=${2:-$1} out
  out=$(run_git "diff of $path" diff --no-color --no-ext-diff --no-textconv -M "$RANGE" -- ":(top,literal)$old" ":(top,literal)$path") || exit $?
  [[ -z $out ]] || printf '%s\n' "$out"
  return 0
}

# is_generated <top> <path>: prints yes or no. The attribute linguist-generated decides; without it, the file name is checked against LOCKFILES
is_generated() {
  local top=$1 path=$2 line value lock
  line=$(run_git "attributes of $path" -C "$top" check-attr linguist-generated -- "$path") || exit $?
  value=${line##*: }
  case $value in
    unset | false) echo no ;;
    unspecified)
      for lock in $LOCKFILES; do
        [[ ${path##*/} != "$lock" ]] || { echo yes; return 0; }
      done
      echo no
      ;;
    *) echo yes ;;
  esac
  return 0
}

# shortcut: several processes per file (about 15 ms, 1000 files took about 15 s), fine up to a few hundred; batch check-attr and jq beyond that
cmd_files() {
  local remote=$1 base=$2 dir=$3 tok rest added removed path old number=0 name content entries="" top generated diff_path entry listing
  require_repo
  [[ -d $dir ]] || die "diff folder" "Folder $dir does not exist."
  # one call per folder: the script never deletes, so a second call would mix its files with the first run's
  [[ ! -e $dir/diff ]] || die "diff folder" "Folder $dir already has diff/. Every run gets its own folder from preflight.sh, so $(rerun)."
  set_range "$remote" "$base"
  mkdir "$dir/diff" || die "diff folder" "Cannot create $dir/diff."
  top=$(run_git "repository root" rev-parse --show-toplevel) || exit $?
  # the changed-file list holds NUL bytes, which a shell variable cannot, so it goes through a file in the folder
  listing="$dir/changed-files.list"
  run_git "changed files of $RANGE" diff "$RANGE" --numstat -z -M > "$listing"
  while IFS= read -r -d '' tok; do
    added=${tok%%$'\t'*}
    rest=${tok#*$'\t'}
    removed=${rest%%$'\t'*}
    path=${rest#*$'\t'}
    old=""
    if [[ -z $path ]]; then # a rename: the next two records are the old and the new path
      IFS= read -r -d '' old
      IFS= read -r -d '' path
    fi
    generated=$(is_generated "$top" "$path") || exit $?
    diff_path=""
    # a pure rename has nothing to read
    # shortcut: a pure rename that also changes the file mode (0/0) is listed without its mode change, upgrade if that matters
    if [[ $generated == no && ( -z $old || $added != 0 || $removed != 0 ) ]]; then
      number=$((number + 1))
      name=$(printf '%03d.diff' "$number")
      content=$(file_diff "$path" "${old:-$path}") || exit $?
      write_file "$dir/diff" "$name" "$content"
      diff_path="$dir/diff/$name"
    fi
    entry=$(jq -nc --arg path "$path" --arg added "$added" --arg removed "$removed" --arg old "$old" --arg generated "$generated" --arg diff "$diff_path" '
      {path: $path, renamedFrom: (if $old == "" then null else $old end),
       added: (if $added == "-" then null else ($added | tonumber) end),
       removed: (if $removed == "-" then null else ($removed | tonumber) end),
       generated: ($generated == "yes"), diff: (if $diff == "" then null else $diff end)}') || die "table entry of $path" "Cannot build the table entry."
    entries+=$entry$'\n'
  done < "$listing"
  printf '%s' "$entries" | jq -sc '.'
  return 0
}

cmd_file() {
  local remote=$1 base=$2 path=$3 old=${4:-}
  require_repo
  set_range "$remote" "$base"
  file_diff "$path" "${old:-$path}"
  return 0
}

main() {
  local cmd=${1:-}
  [[ $# -gt 0 ]] && shift
  case $cmd in
    files) [[ $# -eq 3 ]] || usage; cmd_files "$@" ;;
    file) [[ $# -eq 3 || $# -eq 4 ]] || usage; cmd_file "$@" ;;
    *) usage ;;
  esac
  return $?
}

main "$@"
