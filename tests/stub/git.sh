# Fake git for the tests of preflight.sh create-pr. run.sh sources this file and exports the function, like the fake gh.
# `git fetch` does nothing when STUB_GIT_FETCH=skip (the test repository has a made-up https remote); everything else is the real git.
git() {
  local subcommand=${1:-}
  if [[ $subcommand == fetch && ${STUB_GIT_FETCH:-} == skip ]]; then
    return 0
  fi
  command git "$@"
}
