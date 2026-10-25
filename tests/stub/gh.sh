# Fake gh for the tests. run.sh sources this file and exports the function, so child bash
# processes use it instead of the real gh (no executable bit, no PATH change).
# It answers from files in $STUB_GH_DIR, named after the command: pr-view, issue-view, api.
#   <name>.out   stdout
#   <name>.err   stderr
#   <name>.exit  exit code (default 0)
# Every call is appended to $STUB_GH_DIR/calls.log.
gh() {
  local name code=0
  case ${1:-} in
    api) name=api ;;
    *) name="${1:-}-${2:-}" ;;
  esac
  printf '%s\n' "$*" >> "$STUB_GH_DIR/calls.log"
  [[ -f $STUB_GH_DIR/$name.err ]] && cat "$STUB_GH_DIR/$name.err" >&2
  [[ -f $STUB_GH_DIR/$name.out ]] && cat "$STUB_GH_DIR/$name.out"
  [[ -f $STUB_GH_DIR/$name.exit ]] && code=$(cat "$STUB_GH_DIR/$name.exit")
  return "$code"
}
