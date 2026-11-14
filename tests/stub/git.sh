# Fake git for the tests of the scripts. run.sh sources this file and exports the function, like the fake gh.
# `git fetch` does nothing when STUB_GIT_FETCH=skip (the test repository has a made-up https remote).
# A command whose arguments contain the text of STUB_GIT_FAIL (for example "check-attr" or "rev-parse --show-toplevel") fails with exit 1
# and "fatal: stub failure", so the error path of a git call that fails in the middle of a script can be tested.
# Everything else is the real git.
git() {
  local subcommand=${1:-}
  if [[ -n ${STUB_GIT_FAIL:-} && " $* " == *" $STUB_GIT_FAIL "* ]]; then
    echo "fatal: stub failure" >&2
    return 1
  fi
  if [[ $subcommand == fetch && ${STUB_GIT_FETCH:-} == skip ]]; then
    return 0
  fi
  command git "$@"
}
