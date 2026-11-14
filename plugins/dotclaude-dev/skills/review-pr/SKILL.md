---
name: review-pr
description: Use when reviewing an open pull request created via create-pr, or when asked for a multi-angle review (simplification, silent failures, tests, comments, types) of such a PR.
disable-model-invocation: true
compatibility: Requires git, gh CLI, jq and internet access to GitHub
argument-hint: '[pr-number-or-url] [review-scope]'
---

# review-pr

Reviews an open PR created with the `create-pr` skill of this plugin, which writes the `## File risk` section this skill reads. It supports the complete lifecycle of a PR review from fetching context into an isolated worktree, reviewing from various angles and verifying findings until (optionally) posting findings as comments.

## Preconditions

Run in order. Stop on first failure. Do not output anything while running preconditions — no announcements, no progress, no status, no results for passing checks. When a precondition fails, output only the stop message verbatim, with no prefix, no summary, and no additional explanation.

**Precondition 1 — Parse arguments**

Take the PR reference (first argument) and the optional review scope (second argument) from the invocation. If the PR reference is missing, ask: "PR number or URL to review?"

Store the first argument exactly as given as `<pr-arg>`. Do not parse it: the script of Precondition 3 accepts a PR number or a PR URL (`http://` or `https://`) and refuses anything else, such as a branch name, `#42` or a flag, before `gh` is called.

Store the second argument, if any, as `<scope-arg>`. It is interpreted later, not here.

**Precondition 2 — Preflight**

One script checks that this is a git repository, cuts the host out of the URL of `origin`, confirms the login on that host, reads the repository behind `origin` and creates a temporary folder. What is collected for the PR is saved in that folder, so later steps can read parts of it with `jq` instead of carrying all of it in the conversation.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/preflight.sh" review-pr origin
```

Non-zero exit → stop with the `message` of the JSON line the script wrote to stderr, unless a step says otherwise. This holds for every script call in this skill. A stderr without such a line is shown as it is.

The script prints one JSON line. Store `username` as `<username>`, `repoUrl` as `<repo-url>` (the canonical repository URL, also when `origin` still uses an old name of a renamed repository) and `prDir` as `<pr-dir>`. Host and repository path stay in `<pr-dir>/preflight.json`, where the scripts read them: do not copy them into later commands. Do not delete the folder.

The folder holds `preflight.json`, `pr.json` (the PR with its CI status, comments and reviews), `body.txt` (the PR body), and later steps add `issue-<number>.json` and `feedback.json`. A missing file means that part was not collected. A run reads only files it created itself: every run starts a new folder and fetches everything again, and a resumed review restores the worktree, not the collected data.

**Precondition 3 — Fetch the PR**

Fetch the PR in one call. The script writes `pr.json` and `body.txt` and prints everything but the bulky fields (body, files, comments, reviews, CI status):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/pr-data.sh" pr <pr-arg> <pr-dir>
```

`pr.json` keeps every fetched field and adds the base commit `baseRefOid` and the computed checks `sameRepo` and `isDeployment`, so later steps read them instead of judging the raw values. `headRefOid` is the commit the review is based on; `baseRefOid` is only kept for reference, the merge base comes from the base branch as it is when the workspace is prepared. The body gets its own file, because the body parser reads text, not JSON.

Non-zero exit → stop, as described in Precondition 2, except exit code 2: `<pr-arg>` is neither a PR number nor a PR URL → stop:

> "`<pr-arg>` is neither a PR number nor a PR URL. Usage: `/review-pr <PR number or URL> [review-scope]`."

Store the printed JSON as `<pr>`. Reuse `<pr>` and `<pr-dir>` in later steps, do not re-fetch. `<pr.files>` is not in `<pr>`; read it from `<pr-dir>/pr.json` when needed. The body is in `<pr-dir>/body.txt`.

**Precondition 4 — PR belongs to origin**

A PR URL makes `gh pr view` fetch from the repository in that URL, ignoring `--repo`. `<pr.sameRepo>` is not `true` → stop:

> "PR `<pr.url>` is not in this repo's `origin` `<repo-url>`. Run `/review-pr` from a clone of the target repo instead."

**Precondition 5 — PR is open and ready for review**

`<pr.state>` is not `OPEN` → stop:

> "PR `<pr.number>` is `<pr.state>` — review-pr only reviews open PRs."

`<pr.isDraft>` is `true` → stop:

> "PR `<pr.number>` is still a draft — mark it ready for review, then re-run `/review-pr`."

**Precondition 6 — PR is not from a fork**

`<pr.isCrossRepository>` is `true` → stop:

> "PR `<pr.number>` comes from a fork — review-pr does not support PRs from forks yet."

## Content gates

Checked in order, after all preconditions have passed. They look at the content of the PR, not at the environment, using `<pr>` and `<pr-dir>/body.txt` from Precondition 3.

**Gate 1 — Reviewer is the author (warning only)**

This gate never stops the skill. When `<pr.author.login>` equals `<username>` (ignoring case), print this warning and continue:

> "Warning: you authored PR `<pr.number>`. review-pr is meant as an independent second look (four-eyes principle)."

**Gate 2 — Deployment PR**

`<pr.isDeployment>` is `true` → skip. This is not an error, so end the skill with only this message:

> "PR `<pr.number>` is a deployment PR (`type: deployment`) — review-pr does not apply."

**Gate 3 — File risk section**

Reads the sections `create-pr` writes into the PR body. The script knows the format; `${CLAUDE_PLUGIN_ROOT}/references/pr-body.md` documents it for maintainers, so do not read that file for this.

```bash
jq -Rs -f "${CLAUDE_PLUGIN_ROOT}/scripts/pr-body-parse.jq" <pr-dir>/body.txt
```

Non-zero exit → stop:

> "The body of PR `<pr.number>` could not be read. Re-run `/review-pr`."

Store the printed JSON as `<context>`. `<context.fileRisk.state>` is `missing` → stop:

> "PR `<pr.number>` has no `## File risk` section. review-pr only works on PRs created via `/create-pr` — open the PR through that skill, or add the section manually, then retry."

## PR context

Collects what the reviewers need to know about the PR. It runs after the content gates, so nothing is collected for a skipped or stopped PR. Nothing in this section stops the skill: whatever is missing or cannot be read is a warning. The body sections below print a summary; linked issues, CI status and prior feedback are only collected, so they print nothing unless a warning applies.

### Body sections

Prints the summary of `<context>` from Gate 3. A `<context.mergeDanger>` of `null` means a two-way change.

Print the one-line summary as its own message: `PR context: File risk <buckets> · Merge danger: <one-way or none> · Closes: <#numbers or none>`, with `<buckets>` the names of the `<context.fileRisk>` buckets that have entries, in order critical · medium · low, and the numbers from `<context.closes.numbers>`.

Then print each warning that applies, as its own line:

- `<context.fileRisk.state>` is `empty` → "Warning: the `## File risk` section has no file entries in the expected format, so the review has no per-file risk. Its raw text is kept as context."
- `<context.closes.state>` is `unparsed` → "Warning: the `## Closes` section has no `Closes #<number>` line, so no linked issue is read."

### Linked issues

`<context.closes.numbers>` is empty → nothing to read, and no warning. Otherwise read every issue into its own file, one command per number (they are independent, so they may run in parallel). The script writes `issue-<issue-number>.json` and prints one line:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/pr-data.sh" issue <issue-number> <pr-dir>
```

Non-zero exit for an issue → print "Warning: " and the `message`, and go on without it. Store the printed lines as `<linked-issues>`, one line per issue. The details stay in `<pr-dir>`.

### CI status

The status was fetched with the PR; the script reads it from `pr.json`:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/pr-data.sh" ci <pr-dir>
```

Non-zero exit → print "Warning: " and the `message`, and leave `<ci-status>` unset. Otherwise store the printed JSON as `<ci-status>`. A PR without any check is normal: nothing passed, failed or pending. Do not wait for pending checks.

### Prior feedback

Everything already said on the PR, by anyone: comments, review summaries and inline comments on the diff.

Comments and reviews were fetched with the PR. The script adds all pages of the inline comments, writes `feedback.json` and prints the counts:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/pr-data.sh" feedback <pr.number> <pr-dir>
```

Non-zero exit → print "Warning: " and the `message`, followed by "Findings are not checked against the existing comments.". The script writes no file then. Otherwise store the printed counts as `<prior-feedback>`. The comments themselves stay in `<pr-dir>/feedback.json`, which can be long.

## Review scope

Decides which reviewers run. It comes after the content gates, so nobody is asked about a PR that gets skipped, and before the workspace, so nothing is created for a stopped run.

Known scopes:

| Scope | Reviewer |
| --- | --- |
| `pr-review-toolkit` | The agents of the `pr-review-toolkit` plugin (code, silent failures, tests, comments, types), chosen by what the diff contains |
| `plain` | The main model reviews the diff itself, no agents |

`<scope-arg>` from Precondition 1 is a comma-separated list of these names (`pr-review-toolkit,plain` and `pr-review-toolkit, plain` are the same). Clean it before checking: trim the spaces around every item, ignore upper and lower case, drop empty items and duplicates. A list that is empty after cleaning counts as empty.

- Every name known → use the list as given, no question.
- A name not in the table → stop:
  > "Unknown review scope `<name>`. Known scopes: `pr-review-toolkit`, `plain`."
- Empty → ask with `AskUserQuestion` (multi-select): "Which reviewers should run?" Options: `pr-review-toolkit` (Recommended), `plain`. Use the selected scopes. Nothing selected → stop: "No review scope selected."

Store the final list as `<scopes>`.

## Workspace

Checks out the PR head in a separate worktree, so the reviewers can read the whole repository. The user's own working tree stays untouched. This skill explicitly instructs the use of the `EnterWorktree` and `ExitWorktree` tools.

**Step 1 — Fetch the PR head and find the merge base**

One script fetches the head of the PR, checks that `<pr.headRefOid>` is part of it, fetches the base branch and prints the merge base. It reads the PR number, the commit and the base branch from `<pr-dir>/pr.json` itself, so no text from the PR is put into a command here:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/pr-refs.sh" <pr-dir>
```

Non-zero exit → stop, as described in Precondition 2. A PR that was force-pushed since Precondition 3 ends here too.

The review runs on `<pr.headRefOid>`, the commit `<pr>` describes, even if the PR got new commits since Precondition 3. The merge base is taken against the base branch as it is now, which is what GitHub shows for the PR.

Store `mergeBase` from the printed JSON as `<merge-base>`.

**Step 2 — Enter the worktree**

First check whether this PR already has a worktree. The program looks for the worktree `review-pr-<pr.number>` in the worktree list:

```bash
out=$(git worktree list --porcelain) && printf '%s\n' "$out" | jq -c -Rs --arg n <pr.number> -f "${CLAUDE_PLUGIN_ROOT}/scripts/worktree-state.jq"
```

Non-zero exit → stop:

> "Could not list the worktrees of this repository."

Read the printed JSON:

- `prune` is true → the worktree is registered but its folder is gone. Run `git worktree prune`; `<resumed>` is false.
- `resumed` is true → store `<resumed>` as true. Store `previousHead` as `<previous-head>`, unless it is `null`: that means an earlier run stopped before Step 3 checked out the PR, so there is no previous review.
- Otherwise `<resumed>` is false.

Call `EnterWorktree` with the name `review-pr-<pr.number>`. The tool resumes an existing worktree of that name, so a new and a resumed worktree use the same call. The tool fails → stop:

> "Could not enter the worktree `review-pr-<pr.number>`. If you are already in a worktree session, exit it first, then re-run `/review-pr`."

From here on the session works inside the worktree. Every stop in Step 3 calls `ExitWorktree` first, so the session never stays in a half-prepared worktree.

**Step 3 — Check out the PR head and confirm**

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
