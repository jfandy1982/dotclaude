---
name: create-pr
description: Use when creating a pull request for the current branch, which is already committed and pushed.
compatibility: Requires git, gh CLI, jq and internet access to GitHub
---

# create-pr

## Preconditions

Run in order. Stop on first failure. Do not output anything while running preconditions — no announcements, no progress, no status, no results for passing checks. When a precondition fails, output only the stop message verbatim, with no prefix, no summary, and no additional explanation.

**Precondition 1 — Remote tracking branch**

```bash
git branch --show-current
git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null
```

No output from the first command (detached HEAD) → stop:

> "Not on a branch. Check out a branch, then re-run `/create-pr`."

Store the output as `<branch>`.

If no output from the second command → stop:

> "Branch has no remote tracking branch. Push it first (`git push -u origin <branch>`) then re-run `/create-pr`."

Extract the remote name from the output (e.g. `origin/feat/foo` → remote is `origin`). Store as `<remote>`.

**Precondition 2 — Local branch up to date with remote**

```bash
git fetch <remote>
```

Non-zero exit → stop:

> "Failed to fetch from `<remote>` — check your network connection then re-run `/create-pr`."

```bash
git rev-list --left-right --count @{u}...HEAD
```

The output is `<behind>` and `<ahead>`, separated by a tab. `<behind>` above 0 → stop:

> "Local branch is behind `<remote>` — pull the latest changes (`git pull`) then re-run `/create-pr`."

`<ahead>` above 0 → stop:

> "Local branch has commits that are not on `<remote>` yet — push first (`git push`) then re-run `/create-pr`."

**Precondition 3 — Remote URL and host**

The script cuts the host out of the remote URL offline and prints two lines: the URL and the host.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/remote-host.sh" <remote>
```

Non-zero exit → stop with the `message` of the JSON line the script wrote to stderr, unless a step says otherwise. This holds for every script call in this skill. A stderr without such a line is shown as it is.

Store the first printed line as `<remote-url>` and the second as `<host>`.

**Precondition 4 — Confirm auth**

```bash
gh api user --hostname <host> --jq '.login'
```

Non-zero exit → stop:

> "Not authenticated with `<host>`. Run `gh auth login --hostname <host>` then re-run `/create-pr`."

**Precondition 5 — Repository and default-branch guard**

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/pr-create.sh" repo <host> <remote-url>
```

Store the printed `url` as `<repo-url>`, `path` as `<repo-path>` and `defaultBranch` as `<default-branch>`.

If `<branch>` == `<default-branch>` → stop:

> "Branch `<branch>` is the default branch — create a feature branch first, then re-run `/create-pr`."

**Precondition 6 — Temporary folder**

What is collected for the PR is saved in a temporary folder, so later steps can read parts of it instead of carrying all of it in the conversation. Create the folder:

```bash
d="${TMPDIR:-/tmp}/dotclaude-dev" && mkdir -p -m 700 "$d" && mktemp -d "$d/create-pr-XXXXXX"
```

Non-zero exit → stop:

> "Cannot create a temporary folder for the PR data. The error above names the folder: make it writable for your user or set `TMPDIR` to another folder, then re-run `/create-pr`."

Store the printed path as `<pr-dir>`. Do not delete it.

The folder later holds `diff/` (one diff file per changed file), `labels.json`, `issue-<number>.json`, `alert-<number>.json`, `title.txt` and `body.txt`. A missing file means that part was not collected. A run reads only files it created itself: every run starts a new folder and fetches everything again.

Every stored value is reused in later steps; never re-run a command whose result is stored.

## Mode Detection

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/pr-create.sh" open-pr <host> <repo-url> <branch>
```

The script prints the open PRs of `<branch>` as a JSON array.

- Array not empty → **update mode is the only path**. (not yet implemented — stop with: "Update mode is not yet implemented.")
- Array empty → proceed to create flow.

## Create Flow

Run these steps in this exact order. Inference in Steps 4–7 (labels, file risk, title, body) runs silently — no `AskUserQuestion` stops until the Step 7 combined preview loop. Missing or invalid results are not fixed inline; they are surfaced and corrected in that loop.

### Step 1 — Gather branch context

```bash
git log <remote>/<default-branch>..HEAD
bash "${CLAUDE_PLUGIN_ROOT}/scripts/branch-diff.sh" files <remote> <default-branch> <pr-dir>
```

Use `<remote>/<default-branch>` (not local `<default-branch>`) — Precondition 2 already fetched `<remote>`, so the remote-tracking ref is guaranteed current while the local branch may be stale. `git log` uses two dots (commits reachable from `HEAD` not from `<remote>/<default-branch>`); the script diffs against the merge-base, so upstream changes on `<default-branch>` since the branch was cut don't show up as noise.

The script prints a JSON table with one entry per changed file. Store it as `<file-table>` and do not run the script again; after a failed run do not read any file in `<pr-dir>/diff/`.

- Fields: `path`; `renamedFrom` (old path of a renamed file, else `null`); `added` and `removed` (line counts, `null` for a binary file); `generated`; `diff` (path of the file's diff, or `null`).
- `diff` is set → read that file, one read per file.
- `diff` is `null` and `generated` is false → a pure rename: only listed, nothing to read.
- `generated` is true (a lockfile, or marked `linguist-generated` in `.gitattributes`) → numbers only. Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/branch-diff.sh" file <remote> <default-branch> <path> [<renamedFrom>]` only when a step needs the file's content (which package, major bump); pass `renamedFrom` when it is not `null`. Empty output means the path is not part of this PR: re-check the path in `<file-table>`.

Read `<branch>` (from Precondition 1), the commit messages, `<file-table>`, and the diffs together. Later steps (label inference, PR title, body sections, file risk) all reason from this combined context.

**Checklist.** The script reads only the repository root `CLAUDE.md` and asks git which checklist rows match the changed files:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/pr-checklist.sh" <remote> <default-branch>
```

It prints one JSON line `{state, items}`:

- `none` (no `CLAUDE.md` in the repository root, or no `### PR merge checklist` heading) → no checklist. Continue silently.
- `unusable` (heading found, but no table, or the table lacks a `File pattern` or `Checklist item` column) → `<pr-checklist>` stays empty for this run, and note that the heading was found but unusable. Don't warn here — this is surfaced in the Step 7 combined preview instead, the same place missing/invalid results from other steps are already surfaced and corrected. (This differs from `none`: writing the heading is a deliberate signal of intent, so a broken table under it is worth mentioning, while simply not having the heading is the common, unremarkable case.)
- `ok` → store `items` (the matching rows' items, in table order, duplicates collapsed) as `<pr-checklist>`. An empty list is the common case and is not itself a warning.

The script's answer is final: do not read `CLAUDE.md` or match patterns yourself.

### Step 2 — Issue linking

Ask the author for issue numbers via a plain text prompt: "Issue number(s) this PR closes? (comma-separated, e.g. 38, 42 — or N/A) Issues must be in this repository."

Check that every number is digits only, otherwise ask the author again. For each number, run one command (they are independent, so they may run in parallel). The script writes `issue-<N>.json` into `<pr-dir>` and prints one line, `#<N> <title> (<STATE>)`:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/pr-data.sh" issue <host> <repo-url> <N> <pr-dir>
```

- Exit 11 (`not_found`) → ask with `AskUserQuestion` to correct or drop the number. Not a hard block.
- Any other non-zero exit → stop, as described in Precondition 3.
- State `CLOSED` → ask with `AskUserQuestion` ("Issue #N is already closed — still include?") with options "Include anyway" (keep it) / "Drop it" (remove it from the list). Not a hard block.
- State `OPEN` → keep it.

If `N/A`, skip the confirmation below and continue with `<closes>` and `<issue-context>` empty.

Otherwise, ask with `AskUserQuestion` to show a confirmation listing each issue number with its fetched title:

- Question: "Confirm linked issues:"
- Options:
  - "Use these issues" (Recommended) — preview: each issue number with its fetched title
  - "Edit" — author revises the issue number list via a follow-up plain text prompt; run the command for each new number and apply the checks above

Format as individual `Closes #N` lines.

Store the result as `<closes>`. Read the file `<pr-dir>/issue-<N>.json` of every kept issue once and keep its title, full body and labels as `<issue-context>`. Subsequent steps (file risk, label inference, PR title, body) all use `<issue-context>` as additional signal alongside the branch context from Step 1. Step 7 is responsible for summarizing the issue body down to what's needed for the Why section — `<issue-context>` itself stores the full body, not a pre-truncated version.

### Step 3 — CodeQL alert linking

Ask the author for CodeQL alert numbers via a plain text prompt: "CodeQL alert number(s) this PR fixes? (comma-separated, e.g. 3, 5 — or N/A) Alerts must be in this repository."

Check that every number is digits only, otherwise ask the author again. For each number, run one command (they are independent, so they may run in parallel). The script writes `alert-<N>.json` into `<pr-dir>` and prints one line, `#<N> <ruleId> (<state>)`:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/pr-data.sh" alert <host> <repo-path> <N> <pr-dir>
```

- Exit 11 (`not_found`) → ask with `AskUserQuestion` to correct or drop the number (the alert may not exist, code scanning may be off, or you may lack access). Not a hard block.
- Any other non-zero exit → stop, as described in Precondition 3.
- State other than `open` (`fixed`, `dismissed`) → ask with `AskUserQuestion` ("Alert #N is already <state> — still include?") with options "Include anyway" (keep it) / "Drop it" (remove it from the list). Not a hard block.
- State `open` → keep it.

If `N/A`, skip the confirmation below and continue with `<codeql-context>` empty.

Otherwise, ask with `AskUserQuestion` to show a confirmation listing each alert number with its `ruleId`:

- Question: "Confirm linked CodeQL alerts:"
- Options:
  - "Use these alerts" (Recommended) — preview: each alert number with its `ruleId`
  - "Edit" — author revises the alert number list via a follow-up plain text prompt; run the command for each new number and apply the checks above

Read the file `<pr-dir>/alert-<N>.json` of every kept alert once and keep its `state`, `url`, `ruleId`, `ruleDescription`, `severity`, `message` and `path` as `<codeql-context>`. Subsequent steps (file risk, label inference, PR title, body) use `<codeql-context>` as additional signal alongside `<issue-context>` and the branch context from Step 1. `<codeql-context>` is commonly empty; this is not itself a warning.

There is no `Closes`-equivalent syntax for alerts — GitHub links a fixing branch/PR to an alert automatically once a scan of that branch clears the alert's fingerprint; this is not settable via `gh api`/`gh pr create`, so `create-pr` does not attempt it and adds no PR body section for alerts.

**Manual-assignment gate.** If at least one alert was confirmed (not `N/A`), pause here — the alert's own assignee and its Development-section branch link are both GitHub UI-only actions with no API equivalent, so they can't be automated. Show the author each confirmed alert's `url` (from `<codeql-context>`) and ask them to (1) assign themselves to the alert and (2) link `<branch>` under the alert's Development section, both in the GitHub UI. Then ask with `AskUserQuestion`:

- Question: "Assign yourself to each linked alert and link this branch under its Development section (both in the GitHub UI), then continue."
- Options:
  - "Done, continue" — the only option; proceed to Step 4

This is not verified — `create-pr` has no way to check either action happened — it is an explicit acknowledgment gate, not a hard block on unconfirmed state.

### Step 4 — Label selection

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/pr-create.sh" labels <host> <repo-url> <pr-dir>
```

The script writes all labels to `<pr-dir>/labels.json` and prints `{mode, labels}` with name and description of each label. Store the printed `labels` — reuse in Step 5 (file risk). `--limit 50` in the script is deliberate: the target repos have about 25 labels. Raise it if a repo ever exceeds 50, since labels beyond the limit would fail the verification below.

**Taxonomy detection** is done by the script:

- `mode` is `taxonomy` → the printed labels are the ones with `type:` or `aspect:` prefix; use only those. Suppress all other labels (`priority:`, `status:`, community labels).
- `mode` is `fallback` → no `type:`/`aspect:` labels exist; the printed labels are all repo labels. Skip the enforcement rules below — suggest the most appropriate label from what is available, no minimum-selection required.

**Inference:** From the branch context gathered in Step 1 (commit messages, branch name, changed files, diff), `<issue-context>` from Step 2, and `<codeql-context>` from Step 3, infer a suggested `type:` label. Conventional commit prefixes are the primary signal (`fix:` → `type: bug`, `feat:` → `type: enhancement`, `chore:` → `type: chore`, `docs:` → `type: documentation`, `refactor:` → `type: refactor`); changed files, diff content, and any linked issue reinforce or override when the prefix signal is weak or absent. If a linked issue already carries a `type:` label (from `<issue-context>`) that exists in the fetched label list, treat it as a strong signal — prefer it over a weak/absent prefix signal, and surface it alongside the prefix-derived guess if the two disagree so the author can pick. If no clear signal, no `type:` label is inferred.

From the branch context gathered in Step 1 (changed files, diff content), `<issue-context>` from Step 2, and `<codeql-context>` from Step 3, infer a suggested `aspect:` label. Signal: changed files and diff content, weighed against the fetched label descriptions (Step 4) for topic/area match — e.g. changes concentrated in UI components/templates suggest `aspect: ui`, changes to CLI/API surface suggest `aspect: api`, changes to repo tooling/config suggest `aspect: repo`; a linked CodeQL alert's flagged file path reinforces this same matching (e.g. an alert flagging an auth file alongside a `security` aspect label). No inference is attempted from branch name — too context-dependent to guess reliably. If a linked issue already carries an `aspect:` label that exists in the fetched label list, treat it as a strong signal — prefer it over a weak/absent diff signal, and surface it alongside the diff-derived guess if the two disagree so the author can pick. If no clear signal, no `aspect:` label is inferred.

If no `type:` label could be inferred, leave the slot empty rather than blocking.

#### Verification

Whenever a label is set or changed (initial inference, or a correction made in the Step 7 loop), verify the label name against `<pr-dir>/labels.json` via `jq`, not by eyeballing the array:

```bash
jq --arg name "<label-name>" 'any(.[]; .name == $name)' <pr-dir>/labels.json
```

`true` → the name matches an existing label, proceed. `false` → warn the author and ask them to correct it or drop it — don't pass unknown label names to `gh pr create`.

**Enforcement** (standard mode only):

- If no `type:` label was selected, warn the author but do not block — labels can be adjusted on the PR afterward.
- `type: deployment` cannot be combined with any other `type:` label. If selected alongside another type, warn and ask the author to resolve the conflict before proceeding.

Store the final label set as `<selected-labels>`.

### Step 5 — File risk

Using the `<file-table>` paths from Step 1, `<issue-context>` from Step 2, `<codeql-context>` from Step 3, and the label descriptions fetched in Step 4, classify each file.

| Risk | File characteristics |
| --- | --- |
| **Critical** | Auth/security logic, core business rules, data models, DB migrations |
| **Medium** | Service methods, DTOs, state management, API contracts, CI/CD workflows (`.github/workflows/*`); default for unrecognized files |
| **Low** | Tests, renaming, styling/templates, README, config files |

Classify by what actually changed in the diff, not just the file name — e.g. a one-line version bump in `package-lock.json` stays Low, while hundreds of changed lines from a major upgrade may warrant a higher classification. For a generated file the numbers in `<file-table>` are the evidence (Step 1 says when to read more).

Also weigh each file against the PR's overall intent, not just its own diff in isolation — the same file pair can rank differently depending on what the PR is actually about. In a dependency-update PR, `package.json` is the intentional change and outranks `package-lock.json`, which is just the mechanical follow-on. In a feature PR that happens to add a dependency, the reverse holds — `package-lock.json` (and often `package.json` itself) is a low-risk side effect, and the real risk sits in the feature code elsewhere in the diff. Derive the PR's overall intent from the branch context gathered in Step 1 (commit messages, branch name, dominant change) rather than reasoning about each file in a vacuum.

Use the fetched label descriptions (Step 4) as an additional signal for which areas/topics matter in this repo — e.g. a label described as covering authentication or data access raises attention on `src/users/user.service.ts`; a label described as CI or infrastructure raises attention on `.github/workflows/ci.yml`. Only apply this when a label's description clearly maps to the changed files — don't force a connection that isn't there.

A file flagged by a linked CodeQL alert (`<codeql-context>` from Step 3, matched by the alert's `path`) is raised at least to the risk level for the alert's `severity`: `critical` or `high` → Critical, `medium` → Medium, `low` → Low. This only raises a file, it never lowers one, and `null` means no severity: no raise. Only an alert with state `open` raises a file; a `fixed` or `dismissed` alert the author chose to include is context only. Don't let the file's own name-based default (e.g. `src/users/user.service.ts`, normally Medium) undersell a file with an open security finding on it.

When in doubt, classify up rather than down.

#### Ranking

Within a subsection, two files can share the same bucket but not the same severity — e.g. `db/migrations/0042_drop_users_legacy_id.sql` and `src/users/user.service.ts` can both be Critical, but the migration mutates persisted data and is hard to roll back, while the service change is contained and easy to revert with a follow-up PR. Order files within each subsection by that severity (irreversibility and blast radius first), falling back to alphabetical by path only when two files are genuinely comparable in severity.

#### Format

Build a draft with one subsection per risk level, in order Critical → Medium → Low. All three subsections are always present, even when a risk level has no files — keep the heading and leave the file list empty, no placeholder bullet (one blank line before the next heading, same spacing as a populated subsection). Each file gets a one-line annotation (≤10 words) summarizing what changed in that file, derived from the diff gathered in Step 1 (for a generated file or a pure rename: from its numbers, `renamedFrom` and the other changed files):

```markdown
## File risk

### 🔴 Critical

- `<path>` — <short summary of the change>
- `<path>` — <short summary of the change>

### 🟡 Medium

### 🟢 Low

- `<path>` — <short summary of the change>
```

The format is the contract in `${CLAUDE_PLUGIN_ROOT}/references/pr-body.md`: change it there first, and do not reword or reformat the headings or bullets here.

Store the derived sections as `<file-risk>`.

### Step 6 — PR title

Derive the title from the branch context gathered in Step 1 (commit messages, branch name, changed files, diff), `<issue-context>` from Step 2, and `<codeql-context>` from Step 3.

Determine the dominant conventional commit type and summary by weighing all signals together — commit message(s) (whether one or many), commit prefix counts, what the changed files and diff content actually show, and any type/slug/qualifier embedded in the branch name. No single signal automatically wins (e.g. a single substantial `feat:` commit alongside several trivial `chore:` commits should not lose to `chore:` on count alone; extra details from the branch name could provide additional context, when present). Construct `<type>: <summary>`.

No clear dominant type even after weighing all signals → fall back to the `type:` label from `<selected-labels>` (Step 4) as the type prefix. If no `type:` label was selected either, leave `<title>` as a placeholder needing author input — surfaced as missing in the Step 7 preview.

Format validation against conventional commit format (`<type>(<optional scope>): <description>`) happens in the Step 7 preview, not here.

Store the derived title as `<title>`.

### Step 7 — PR description (body)

Derive a combined "What" and "Why" from the branch context gathered in Step 1 (commit messages, branch name, changed files, diff), `<issue-context>` from Step 2, and `<codeql-context>` from Step 3:

- **What** — summarize the actual change: what was added, fixed, or modified. Derived from the diff content and commit messages together, not just commit messages alone.
- **Why** — summarize the motivation. If issue(s) were linked in Step 2, derive Why primarily from the fetched issue body/bodies in `<issue-context>`. If CodeQL alert(s) were linked in Step 3 and no issue provides a motivation, derive Why from the alert's `ruleDescription`/`message` instead. Otherwise, derive from commit messages (e.g. references to a bug, a goal stated in a commit body). If no motivation is evident from any source, state that explicitly rather than inventing one. Start at the motivation itself — no intro sentence, no restating the title or What — and keep it to 1–5 sentences.

Also decide `<merge-danger>` from the same context and `<file-risk>` from Step 5. The default is **two-way**: reverting the PR undoes the change. Only call it **one-way** when the change is destructive or cannot be undone by reverting the PR — data loss, a schema change old code can't read, a removed or changed public API or contract, or external side effects once deployed. If Step 5 put a migration, deletion, or public-contract file in Critical, decide this explicitly rather than defaulting. Two-way → `<merge-danger>` stays empty. One-way → `<merge-danger>` is a justification that leads with the irreversible thing and names a concrete change from the diff (e.g. "Drops column `users.legacy_id` in `db/migrations/0042_drop_users_legacy_id.sql`; reverting the PR won't restore the data."). "Risky" alone is not a justification.

Assemble `<body>` as defined in `${CLAUDE_PLUGIN_ROOT}/references/pr-body.md`: a `## What` section with the derived What text, followed by a `## Why` section with the derived Why text, followed by `<file-risk>` from Step 5, followed by a `## Merge danger` section built from `<merge-danger>` (omitted if `<merge-danger>` is empty), followed by a `## Closes` section built from `<closes>` (omitted if `<closes>` is empty), followed by a `## PR checklist` section built from `<pr-checklist>` (omitted entirely if `<pr-checklist>` is empty):

```markdown
## PR checklist

- [ ] <checklist item 1>
- [ ] <checklist item 2>
```

Rendered as standard GitHub Flavored Markdown task-list items (unchecked) — GitHub renders these as interactive checkboxes on the PR page, but `create-pr` itself never checks them and never reads their checked state back.

Default `<draft-state>` to "ready for review".

#### Combined preview and confirmation loop

Render `<title>`, `<selected-labels>`, the full `<body>` (What/Why + File risk + Merge danger + Closes + PR checklist), and `<draft-state>` together as one combined preview. If `<title>` is a placeholder or fails conventional commit format, or if no `type:` label was inferred, call this out explicitly in the preview rather than silently presenting it as final. If `<merge-danger>` is empty, add the one-line note "Merge danger: two-way (section omitted)" to the preview so the author can tell it was considered — preview only, never part of `<body>`. If the Step 1 checklist script reported `unusable`, also call this out explicitly (e.g. "Note: this repo's CLAUDE.md has a PR merge checklist heading, but its table couldn't be read — no checklist section was added") — informational only, it doesn't block "Looks good, create it."

Ask with `AskUserQuestion`:

- Question: "Does this PR look right?"
- Put the full combined preview text into the `preview` field of every option, so it is visible in the dialog whichever option has focus; do not also print it as text above the dialog.
- Options:
  - "Looks good, create it" (Recommended) — exit the loop, proceed to Step 8
  - "Change body" — second-level AskUserQuestion (multiSelect): which section(s) to change — What / Why / File risk / Merge danger. For each selected section, take a free-text correction from the author and update `<body>` accordingly. Re-render the combined preview and repeat this question.
  - "Change something else" — second-level AskUserQuestion (multiSelect): which of — Title / Labels / Issue links / CodeQL alert links / Draft or ready for review. For each selected item, take a free-text correction from the author (label corrections still go through the Step 4 verification check; issue-link corrections still go through the Step 2 not-found/already-closed checks; CodeQL alert-link corrections still go through the Step 3 not-found/already-fixed-or-dismissed checks; "Draft or ready for review" toggles `<draft-state>` between "Draft" and "Ready for review"). Re-render the combined preview and repeat this question.

Loop has no fixed iteration cap — repeat until the author chooses "Looks good, create it."

### Step 8 — Create PR

Write `<title>` as plain text to `<pr-dir>/title.txt` and `<body>` to `<pr-dir>/body.txt` with the Write tool, exactly as shown in the preview. Never put title or body into a shell command: both contain backticks, which the shell would run.

Check that the body can be read by the other skills:

```bash
jq -Rs -f "${CLAUDE_PLUGIN_ROOT}/scripts/pr-body-parse.jq" <pr-dir>/body.txt
```

Expected: `fileRisk.state` is `ok` and `closes.numbers` equals the issue numbers in `<closes>`. Anything else means the body drifted from the contract: show the difference in the preview, go back to the loop above, and run no `gh pr create`.

Then create the PR. Write `yes` for a draft (`<draft-state>` is "Draft") and `no` otherwise, followed by one argument per label in `<selected-labels>` (none if empty). The script reads both files and prints the PR URL:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/pr-create.sh" create <host> <repo-url> <pr-dir> <yes|no> ["<label>" ...]
```

Display the PR URL.
