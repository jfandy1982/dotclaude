---
name: review-pr
description: Use when reviewing an open pull request created via create-pr, or when asked for a multi-angle review (simplification, silent failures, tests, comments, types) of such a PR.
compatibility: Requires git, gh CLI and internet access to GitHub
argument-hint: '[pr-number-or-url] [review-scope]'
---

# review-pr

Reviews an open PR created with the `create-pr` skill of this plugin, which writes the `## File risk` section this skill reads. It supports the complete lifecycle of a PR review from fetching context into an isolated worktree, reviewing from various angles and verifying findings until (optionally) posting findings as comments.

## Preconditions

Run in order. Stop on first failure. Do not output anything while running preconditions — no announcements, no progress, no status, no results for passing checks. When a precondition fails, output only the stop message verbatim, with no prefix, no summary, and no additional explanation.

**Precondition 1 — Parse arguments**

Take the PR reference (first argument) and the optional review scope (second argument) from the invocation. If the PR reference is missing, ask: "PR number or URL to review?"

Store the first argument exactly as given as `<pr-arg>`. Do not parse it: `gh pr view` in Precondition 6 resolves PR numbers and PR URLs itself.

Store the second argument, if any, as `<scope-arg>`. It is interpreted later, not here.

**Precondition 2 — Git repository**

```bash
git rev-parse --is-inside-work-tree 2>/dev/null
```

Output other than exactly `true` → stop.

> "Not inside a git repository. Run `/review-pr` from a clone of the target repo."

**Precondition 3 — Origin host**

```bash
git remote get-url origin 2>/dev/null
```

No output → stop:

> "No `origin` remote configured in this repository."

Store the output as `<origin-url>`. Only the host is needed before the auth check; it is cut out offline, for every remote URL form (`https://`, `git@host:`, `ssh://…:port/`, `user@` in the URL):

```bash
printf '%s\n' '<origin-url>' | sed -E 's#^[a-z+]+://##; s#^[^@/]*@##; s#[:/].*##'
```

No output → stop:

> "Cannot read a host from the `origin` URL `<origin-url>`."

Store the output as `<host>`.

**Precondition 4 — Confirm auth**

```bash
gh api user --hostname <host> --jq '.login'
```

Non-zero exit → stop:

> "Not authenticated with `<host>`. Run `gh auth login --hostname <host>` then re-run `/review-pr`."

Store the printed login as `<username>`.

**Precondition 5 — Origin repository**

```bash
gh repo view <origin-url> --json url --jq '.url'
```

Non-zero exit → stop:

> "`origin` `<origin-url>` is not a GitHub repository on `<host>`, or you lack access to it."

Store the printed URL as `<repo-url>`. It is the canonical `https://<host>/<owner>/<repo>`, also when `origin` still uses an old name of a renamed repository.

**Precondition 6 — Fetch the PR**

```bash
gh pr view <pr-arg> --repo <repo-url> \
  --json number,url,title,body,labels,files,author,state,isDraft,isCrossRepository,baseRefName,headRefName,headRefOid,additions,deletions,changedFiles \
  --jq '. + {
    sameRepo:     (.url | test("^\\Q<repo-url>/pull/\\E"; "i")),
    isDeployment: any(.labels[]; .name == "type: deployment"),
    hasFileRisk:  (.body | test("(?im)^[ \t]*## file risk[ \t]*\r?$"))
  }'
```

The `--jq` keeps every fetched field and adds computed checks, so later steps read them instead of judging the raw values.

Non-zero exit → stop:

> "`<pr-arg>` could not be fetched as a PR of `<repo-url>` — it may not exist, may not be a PR number or URL, or you may lack access."

Store the result as `<pr>`. Reuse `<pr>` in later steps, do not re-fetch.

**Precondition 7 — PR belongs to origin**

A PR URL makes `gh pr view` fetch from the repository in that URL, ignoring `--repo`. `<pr.sameRepo>` is not `true` → stop:

> "PR `<pr.url>` is not in this repo's `origin` `<repo-url>`. Run `/review-pr` from a clone of the target repo instead."

**Precondition 8 — PR is open and ready for review**

`<pr.state>` is not `OPEN` → stop:

> "PR `<pr.number>` is `<pr.state>` — review-pr only reviews open PRs."

`<pr.isDraft>` is `true` → stop:

> "PR `<pr.number>` is still a draft — mark it ready for review, then re-run `/review-pr`."

**Precondition 9 — PR is not from a fork**

`<pr.isCrossRepository>` is `true` → stop:

> "PR `<pr.number>` comes from a fork — review-pr does not support PRs from forks yet."

## Content gates

Checked in order, after all preconditions have passed. They look at the content of the PR, not at the environment, using `<pr>` from Precondition 6.

**Gate 1 — Reviewer is the author (warning only)**

This gate never stops the skill. When `<pr.author.login>` equals `<username>` (ignoring case), print this warning and continue:

> "Warning: you authored PR `<pr.number>`. review-pr is meant as an independent second look (four-eyes principle)."

**Gate 2 — Deployment PR**

`<pr.isDeployment>` is `true` → skip. This is not an error, so end the skill with only this message:

> "PR `<pr.number>` is a deployment PR (`type: deployment`) — review-pr does not apply."

**Gate 3 — File risk section**

`<pr.hasFileRisk>` is not `true` → stop:

> "PR `<pr.number>` has no `## File risk` section. review-pr only works on PRs created via `/create-pr` — open the PR through that skill, or add the section manually, then retry."

## Review scope

Decides which reviewers run. It comes after the content gates, so nobody is asked about a PR that gets skipped, and before the workspace, so nothing is created for a stopped run.

Known scopes:

| Scope | Reviewer |
| --- | --- |
| `pr-review-toolkit` | The agents of the `pr-review-toolkit` plugin (code, silent failures, tests, comments, types), chosen by what the diff contains |
| `plain` | The main model reviews the diff itself, no agents |

`<scope-arg>` from Precondition 1 is a comma-separated list of these names (e.g. `pr-review-toolkit,plain`).

- Every name known → use the list as given, no question.
- A name not in the table → stop:
  > "Unknown review scope `<name>`. Known scopes: `pr-review-toolkit`, `plain`."
- Empty → ask with `AskUserQuestion` (multi-select): "Which reviewers should run?" Options: `pr-review-toolkit` (Recommended), `plain`. Use the selected scopes. Nothing selected → stop: "No review scope selected."

Store the final list as `<scopes>`.

## Workspace

Checks out the PR head in a separate worktree, so the reviewers can read the whole repository. The user's own working tree stays untouched. This skill explicitly instructs the use of the `EnterWorktree` and `ExitWorktree` tools.

**Step 1 — Fetch the PR head**

```bash
git fetch origin pull/<pr.number>/head
```

Non-zero exit → stop:

> "Could not fetch the head of PR `<pr.number>` from `origin`."

The review runs on `<pr.headRefOid>`, the commit `<pr>` describes, even if the PR got new commits since Precondition 6. That commit only has to exist locally:

```bash
git cat-file -t <pr.headRefOid> 2>/dev/null
```

Output other than exactly `commit` → the PR was force-pushed after Precondition 6 → stop:

> "PR `<pr.number>` was force-pushed while review-pr was starting. Re-run `/review-pr`."

**Step 2 — Find the merge base**

```bash
git fetch origin +refs/heads/<pr.baseRefName>:refs/remotes/origin/<pr.baseRefName>
```

Non-zero exit → stop:

> "Could not fetch base branch `<pr.baseRefName>` of PR `<pr.number>` from `origin`."

```bash
git merge-base <pr.headRefOid> refs/remotes/origin/<pr.baseRefName>
```

Non-zero exit → stop:

> "Could not determine the merge base of PR `<pr.number>` with `<pr.baseRefName>`."

Store the printed commit as `<merge-base>`.

**Step 3 — Enter the worktree**

First check whether this PR already has a worktree:

```bash
git worktree list --porcelain
```

Non-zero exit → stop:

> "Could not list the worktrees of this repository."

A `worktree <path>` line whose path ends with `/.claude/worktrees/review-pr-<pr.number>` means the worktree exists. If its entry is marked `prunable`, run `git worktree prune` and treat it as not existing. Otherwise store `<resumed>` as true and the path as `<existing-path>`, and read the commit it is on:

```bash
git -C <existing-path> rev-parse HEAD
```

Store the printed commit as `<previous-head>`, but only if the entry has a `detached` line. An entry with a `branch` line instead means an earlier run stopped before Step 4 checked out the PR, so there is no previous review: leave `<previous-head>` unset. No such `worktree` line at all → `<resumed>` is false.

Call `EnterWorktree` with the name `review-pr-<pr.number>`. The tool resumes an existing worktree of that name, so a new and a resumed worktree use the same call. The tool fails → stop:

> "Could not enter the worktree `review-pr-<pr.number>`. If you are already in a worktree session, exit it first, then re-run `/review-pr`."

From here on the session works inside the worktree. Every stop in Step 4 calls `ExitWorktree` first, so the session never stays in a half-prepared worktree.

**Step 4 — Check out the PR head and confirm**

If `<resumed>` is true, the worktree must be clean first:

```bash
git status --porcelain
```

Any output → call `ExitWorktree` with `keep`, then stop:

> "The existing worktree `review-pr-<pr.number>` has local changes. Clean it up or remove it, then re-run `/review-pr`."

```bash
git checkout --detach <pr.headRefOid>
```

Non-zero exit → call `ExitWorktree` (`remove` with `discard_changes: true` when `<resumed>` is false, `keep` when it is true), then stop:

> "Could not check out PR `<pr.number>` at `<pr.headRefOid>`."

```bash
git rev-parse --show-toplevel
```

Store the printed path as `<worktree>`.

Printing the confirmation is the last action of this step, not a separate step. Your next message after the commands above must be this confirmation, as its own message and before any other question or tool call; a run without it is wrong. This applies to a new and to a resumed worktree alike: the first line tells which one it is. Replace the variables, print every line separately and the title exactly as it is, without quotes or escaping:

> ✅ <first line>  
> PR #<pr.number>: <pr.title>  
> Author: @<pr.author.login>  
> Branch: `<pr.headRefName>` should be merged into `<pr.baseRefName>`  
> Changes: +<pr.additions> and -<pr.deletions> across <pr.changedFiles> files

The first line is:

- `<resumed>` is false → ``Worktree is ready for review: `review-pr-<pr.number>` ``
- `<resumed>` is true → ``Reusing existing worktree for review: `review-pr-<pr.number>` ``

If `<previous-head>` is set, add one more line directly below the first line:

- `<previous-head>` equals `<pr.headRefOid>` → `Nothing new since the last review.`
- `git merge-base --is-ancestor <previous-head> <pr.headRefOid>` exits 0 → `<commit-count> new commits since the last review.`, with `<commit-count>` from `git rev-list --count <previous-head>..<pr.headRefOid>`.
- The same command exits 1 → `The PR was force-pushed: the previously reviewed commit is no longer part of it.`
- Any other exit code → add no line.

## Review (placeholder)

Stands in for the review flow, which will replace this section. Run in the worktree:

```bash
git diff --stat <merge-base> <pr.headRefOid>
```

Non-zero exit → continue with Cleanup, without the listing. Otherwise print the output as its own message, below the heading "Changes of PR `<pr.number>` since `<pr.baseRefName>`:". This is a listing, not a review: add no findings and no verdict.

## Cleanup

Leaves the worktree. It runs last, and the review flow will be placed between the workspace and this section.

Ask with `AskUserQuestion`: "Remove or keep the worktree `review-pr-<pr.number>`?" Options: Remove (Recommended), Keep.

**Keep** → call `ExitWorktree` with `keep`, then tell the user:

> "Kept `<worktree>`, detached at `<pr.headRefOid>`. Remove it later with `git worktree remove <worktree>` and `git branch -D worktree-review-pr-<pr.number>`."

**Remove** → first check that the worktree holds nothing but the PR head:

```bash
git status --porcelain
git rev-parse HEAD
```

Any output from `git status --porcelain`, or a printed commit other than `<pr.headRefOid>` → show what was found and ask whether to remove anyway or keep it. Otherwise call `ExitWorktree` with `remove` and `discard_changes: true`. The tool always refuses without that flag, because it counts the PR's own commits as work that exists only in the worktree. The PR commits stay on GitHub.

End the skill here, as it is still in development. Do not review the diff and print no verdict and no summary: the review flow does not exist yet, and the listing above is only a placeholder.
