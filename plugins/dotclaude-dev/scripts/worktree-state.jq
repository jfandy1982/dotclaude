# Finds the review worktree of one PR in the output of `git worktree list --porcelain`.
# Input: the output as raw text (jq -Rs). Argument: --arg n <pr-number>.
# Output: {resumed, prune, path, previousHead}
#   resumed       the worktree exists and is usable
#   prune         the worktree is registered but its folder is gone: run `git worktree prune` first
#   path          the worktree path, null when there is none
#   previousHead  the commit a resumed worktree is on, only when it is detached (an earlier run reached the checkout), else null
# jq 1.6 compatible: every `if` has an `else`.

def field($lines; $key):
  ([$lines[] | select(startswith($key + " ")) | .[($key | length) + 1:]] | first) // null;

[ split("\n\n")[]
  | split("\n")
  | map(select(length > 0))
  | select(length > 0)
  | { path: field(.; "worktree"),
      head: field(.; "HEAD"),
      detached: any(.[]; . == "detached"),
      prunable: any(.[]; . == "prunable" or startswith("prunable ")) } ]
| map(select(.path != null and (.path | endswith("/.claude/worktrees/review-pr-" + $n))))
| first
| if . == null then {resumed: false, prune: false, path: null, previousHead: null}
  elif .prunable then {resumed: false, prune: true, path: .path, previousHead: null}
  else {resumed: true, prune: false, path: .path, previousHead: (if .detached then .head else null end)}
  end
