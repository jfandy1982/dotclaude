# Fake gh for the tests. run.sh sources this file and exports the function, so child bash
# processes use it instead of the real gh (no executable bit, no PATH change).
# It answers from files in $STUB_GH_DIR, named after the command: pr-view, issue-view, label-list, ...
# For `gh api` the name is api-<word>, where <word> is the last non-numeric segment of the endpoint
# (user, pulls, comments, alerts); without such a file the answer comes from api.
#   <name>.out   stdout
#   <name>.err   stderr
#   <name>.exit  exit code (default 0)
#   <name>.args  optional: one text per line, each must appear in the arguments of the call,
#                otherwise the call fails with exit 97 and says which text is missing (a wrong flag no longer passes)
# Every call is appended to $STUB_GH_DIR/calls.log.
gh() {
  local name code=0 endpoint segment segment_name="" text skip
  local -a shift_args
  case ${1:-} in
    api)
      name=api
      # the endpoint is the first argument after `api` that is no flag and no flag value
      endpoint=""
      shift_args=("${@:2}")
      skip=0
      for segment in ${shift_args[@]+"${shift_args[@]}"}; do
        if [[ $skip -eq 1 ]]; then skip=0; continue; fi
        case $segment in
          --hostname | --jq | -q | --method | -X | -H | --header | -f | -F | --field | --raw-field | --input | --cache) skip=1 ;;
          -*) ;;
          *) endpoint=$segment; break ;;
        esac
      done
      endpoint=${endpoint%%\?*}
      for segment in $(printf '%s' "$endpoint" | tr '/' ' '); do
        [[ $segment =~ ^[0-9]+$ ]] || segment_name=$segment
      done
      if [[ -n $segment_name ]] && ls "$STUB_GH_DIR/api-$segment_name".* > /dev/null 2>&1; then
        name="api-$segment_name"
      fi
      ;;
    *) name="${1:-}-${2:-}" ;;
  esac
  printf '%s\n' "$*" >> "$STUB_GH_DIR/calls.log"
  if [[ -f $STUB_GH_DIR/$name.args ]]; then
    while IFS= read -r text; do
      [[ -z $text ]] && continue
      case " $* " in
        *"$text"*) ;;
        *)
          printf 'stub gh: the call lacks "%s": gh %s\n' "$text" "$*" >&2
          return 97
          ;;
      esac
    done < "$STUB_GH_DIR/$name.args"
  fi
  [[ -f $STUB_GH_DIR/$name.err ]] && cat "$STUB_GH_DIR/$name.err" >&2
  [[ -f $STUB_GH_DIR/$name.out ]] && cat "$STUB_GH_DIR/$name.out"
  [[ -f $STUB_GH_DIR/$name.exit ]] && code=$(cat "$STUB_GH_DIR/$name.exit")
  return "$code"
}
