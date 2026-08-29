---
name: create-pr
description: Use when creating or updating a pull request — handles preconditions, label selection, PR body assembly, and update flow. Assumes branch is already committed and pushed.
compatibility: Requires git, gh CLI with jq and internet access to GitHub
---

# create-pr

## Preconditions

Run in order. Stop on first failure. Do not output anything while running preconditions — no announcements, no progress, no status, no results for passing checks. When a precondition fails, output only the stop message verbatim, with no prefix, no summary, and no additional explanation.

**Precondition 1 — Remote tracking branch**

```bash
git branch --show-current
git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null
```

Store the current branch name as `<branch>` — reuse in later steps, do not call `git branch --show-current` again.

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
git rev-list HEAD..@{u}
```

If the output is non-empty → local is behind the remote → stop:

> "Local branch is behind `<remote>` — pull the latest changes (`git pull`) then re-run `/create-pr`."

```bash
git rev-list @{u}..HEAD
```

If the output is non-empty → local is ahead of the remote (missing commits) → stop:

> "Local branch has missing commits — push first (`git push`) then re-run `/create-pr`."

**Precondition 3 — Default-branch guard**

```bash
DEFAULT=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')
```

Store the default branch name as `<DEFAULT>` — reuse in later steps, do not call `gh repo view` again. Reuse `<branch>` from Precondition 1 — do not call `git branch --show-current` again.

If `<branch>` == `<DEFAULT>` → stop:

> "Branch `<branch>` is the default branch — create a feature branch first, then re-run `/create-pr`."

**Precondition 4 — Detect GitHub host**

```bash
git remote get-url <remote>
```

Parse the hostname:

- HTTPS: `https://github.example.com/org/repo.git` → `github.example.com`
- SSH: `git@github.example.com:org/repo.git` → `github.example.com`

Store as `<host>`.

**Precondition 5 — Confirm auth and resolve assignee**

```bash
gh api user | jq -r '.login'
```

- Non-zero exit → stop:
  > "Not authenticated with `<host>`. Run `gh auth login --hostname <host>` then re-run `/create-pr`."
- Success → store the returned login as `<username>` and display:
  > "Authenticated with `<host>`. Assignee of new PR will be: `<username>`"

Continue without asking for confirmation.

## Mode Detection

```bash
gh pr list --head <branch> --state open --json number,title
```

- Open PR found → **update mode is the only path**. (not yet implemented — stop with: "Update mode is not yet implemented.")
- No open PR found → proceed to create flow.

## Create Flow

Run these steps in this exact order. Inference in Steps 3–6 (file risk, labels, title, body) runs silently — no `AskUserQuestion` stops until the Step 6 combined preview loop. Missing or invalid results are not fixed inline; they are surfaced and corrected in that loop.

### Step 1 — Gather branch context

```bash
git log <remote>/<DEFAULT>..HEAD
git diff <remote>/<DEFAULT>...HEAD --name-only
git diff <remote>/<DEFAULT>...HEAD
```

Use `<remote>/<DEFAULT>` (not local `<DEFAULT>`) — Precondition 2 already fetched `<remote>`, so the remote-tracking ref is guaranteed current while the local branch may be stale. `git log` uses two dots (commits reachable from `HEAD` not from `<remote>/<DEFAULT>`); `git diff` uses three dots (diff against the merge-base) so upstream changes on `<DEFAULT>` since the branch was cut don't show up as noise.

Read `<branch>` (from Precondition 1), the commit messages, the list of changed files, and the actual diff content together. Later steps (label inference, PR title, body sections, file risk) all reason from this combined context — do not re-run these commands per step.

### Step 2 — Issue linking

Ask the author for issue numbers via a plain text prompt: "Issue number(s) this PR closes? (comma-separated, e.g. 38, 42 — or N/A) Remark: Issues have to exist in THIS repository."

For each number provided:

```bash
gh issue view <N> --json title,body,labels
```

- Not found → use the AskUserQuestion tool to warn and ask the author to correct or drop it. Not a hard block.
- Already closed → use the AskUserQuestion tool to warn ("Issue #N is already closed — still include?") with options "Include anyway" / "Drop it". Not a hard block.
- Found → fetch title + full issue body + labels.

If `N/A`, skip the confirmation below and continue with `<closes>` and `<issue-context>` empty.

Otherwise, use the AskUserQuestion tool to show a confirmation listing each issue number with its fetched title:

- Question: "Confirm linked issues:"
- Options:
  - "Use these issues" (Recommended) — preview: each issue number with its fetched title
  - "Edit" — author revises the issue number list via a follow-up plain text prompt

Format as individual `Closes #N` lines.

Store the result as `<closes>` and the fetched issue summaries (including each issue's full body and labels) as `<issue-context>`. Subsequent steps (file risk, label inference, PR title, body) all use `<issue-context>` as additional signal alongside the branch context from Step 1 — do not re-fetch issues per step. Step 6 is responsible for summarizing the issue body down to what's needed for the Why section — `<issue-context>` itself stores the full body, not a pre-truncated version.

### Step 3 — File risk

Using the changed files list from Step 1 and `<issue-context>` from Step 2, classify each file.

| Risk | File characteristics |
| --- | --- |
| **Critical** | Auth/security logic, core business rules, data models, DB migrations |
| **Medium** | Service methods, DTOs, state management, API contracts, CI/CD workflows (`.github/workflows/*`); default for unrecognized files |
| **Low** | Tests, renaming, styling/templates, README, config files |

Classify by what actually changed in the diff, not just the file name — e.g. a one-line version bump in a lockfile or config file stays Low/Medium as appropriate, while a substantial change to the same file may warrant a higher classification.

Also weigh each file against the PR's overall intent, not just its own diff in isolation — the same file pair can rank differently depending on what the PR is actually about. In a dependency-update PR, `package.json` is the intentional change and outranks its lockfile, which is just the mechanical follow-on. In a feature PR that happens to add a dependency, the reverse holds — the lockfile (and often `package.json` itself) is a low-risk side effect, and the real risk sits in the feature code elsewhere in the diff. Derive the PR's overall intent from the branch context gathered in Step 1 (commit messages, branch name, dominant change) rather than reasoning about each file in a vacuum.

When in doubt, classify up rather than down.

#### Ranking

Within a subsection, two files can share the same bucket but not the same severity — e.g. a DB migration and a service-layer wiring change can both be Critical, but the migration mutates persisted data and is hard to roll back, while the service change is contained and easy to revert with a follow-up PR. Order files within each subsection by that severity (irreversibility and blast radius first), falling back to alphabetical by path only when two files are genuinely comparable in severity.

#### Format

Build a draft with one subsection per risk level, in order Critical → Medium → Low. All three subsections are always present, even when a risk level has no files — keep the heading and leave the file list empty, no placeholder bullet (one blank line before the next heading, same spacing as a populated subsection). Each file gets a one-line annotation (≤10 words) summarizing what changed in that file, derived from the diff content gathered in Step 1:

```markdown
## File risk

### 🔴 Critical

- `<path>` — <short summary of the change>
- `<path>` — <short summary of the change>

### 🟡 Medium

### 🟢 Low

- `<path>` — <short summary of the change>
```

The heading text (`## File risk`, `### 🔴 Critical`, `### 🟡 Medium`, `### 🟢 Low`), the fact that all three subsections always appear (with no bullets when a bucket is empty), and the `` `<path>` — <summary> `` bullet format are a stable contract other skills parse from the PR body — do not reword or reformat them.

Store the derived sections as `<file-risk>`.

### Step 4 — Label selection

```bash
gh label list --json name --limit 50
```

**Taxonomy detection:** Filter results to labels with `type:` or `aspect:` prefixes.

- If matching labels exist → use only those. Suppress all other labels (`priority:`, `status:`, community labels).
- If no `type:`/`aspect:` labels exist → **fallback mode**: use all repo labels unfiltered. Skip the enforcement rules below — suggest the most appropriate label from what is available, no minimum-selection required.

**Inference:** From the branch context gathered in Step 1 (commit messages, branch name, changed files, diff) and `<issue-context>` from Step 2, infer a suggested `type:` label. Conventional commit prefixes are the primary signal (`fix:` → `type: bug`, `feat:` → `type: enhancement`, `chore:` → `type: chore`, `docs:` → `type: documentation`, `refactor:` → `type: refactor`); changed files, diff content, and any linked issue reinforce or override when the prefix signal is weak or absent. If a linked issue already carries a `type:` label (from `<issue-context>`) that exists in the fetched label list, treat it as a strong signal — prefer it over a weak/absent prefix signal, and surface it alongside the prefix-derived guess if the two disagree so the author can pick. If no clear signal, no `type:` label is inferred.

If a linked issue carries an `aspect:` label (from `<issue-context>`) that exists in the fetched label list, infer it as the suggested `aspect:` label. No other `aspect:` inference is attempted — without a linked issue carrying one, no `aspect:` label is inferred. No inference is attempted for `aspect:` from branch context — too context-dependent to guess reliably.

If no `type:` label could be inferred, leave the slot empty rather than blocking.

#### Verification

Whenever a label is set or changed (initial inference, or a correction made in the Step 6 loop), verify the label name against the fetched label list (exact match). If a name doesn't match any existing label, warn the author and ask them to correct it or drop it — don't pass unknown label names to `gh pr create`.

**Enforcement** (standard mode only):

- If no `type:` label was selected, warn the author but do not block — labels can be adjusted on the PR afterward.
- `type: deployment` cannot be combined with any other `type:` label. If selected alongside another type, warn and ask the author to resolve the conflict before proceeding.

Store the final label set as `<selected-labels>`.

### Step 5 — PR title

Derive the title from the branch context gathered in Step 1 (commit messages, branch name, changed files, diff) and `<issue-context>` from Step 2 — do not re-run `git branch`/`git log`/`git diff`.

Determine the dominant conventional commit type and summary by weighing all signals together — commit message(s) (whether one or many), commit prefix counts, what the changed files and diff content actually show, and any type/slug/qualifier embedded in the branch name. No single signal automatically wins (e.g. a single substantial `feat:` commit alongside several trivial `chore:` commits should not lose to `chore:` on count alone; extra details from the branch name could provide additional context, when present). Construct `<type>: <summary>`.

No clear dominant type even after weighing all signals → fall back to the `type:` label from `<selected-labels>` (Step 4) as the type prefix. If no `type:` label was selected either, leave `<title>` as a placeholder needing author input — surfaced as missing in the Step 6 preview.

Format validation against conventional commit format (`<type>(<optional scope>): <description>`) happens in the Step 6 preview, not here.

Store the derived title as `<title>`.

### Step 6 — PR description (body)

Derive a combined "What" and "Why" from the branch context gathered in Step 1 (commit messages, branch name, changed files, diff) and `<issue-context>` from Step 2 — do not re-run `git log`/`git diff`:

- **What** — summarize the actual change: what was added, fixed, or modified. Derived from the diff content and commit messages together, not just commit messages alone.
- **Why** — summarize the motivation. If issue(s) were linked in Step 2, derive Why primarily from the fetched issue body/bodies in `<issue-context>`. Otherwise, derive from commit messages (e.g. references to a bug, a goal stated in a commit body). If no motivation is evident from either source, state that explicitly rather than inventing one.

Assemble `<body>` as the derived What/Why text, followed by `<file-risk>` from Step 3, followed by a `## Closes` section built from `<closes>`. Omit the `## Closes` section entirely if `<closes>` is empty.

Default `<draft-state>` to "ready for review".

#### Combined preview and confirmation loop

Render `<title>`, `<selected-labels>`, the full `<body>` (What/Why + File risk + Closes), and `<draft-state>` together as one combined preview. If `<title>` is a placeholder or fails conventional commit format, or if no `type:` label was inferred, call this out explicitly in the preview rather than silently presenting it as final.

Use the AskUserQuestion tool to ask:

- Question: "Does this PR look right?"
- Options:
  - "Looks good, create it" (Recommended) — exit the loop, proceed to Step 7
  - "Change body" — second-level AskUserQuestion (multiSelect): which section(s) to change — What / Why / File risk / Closes. For each selected section, take a free-text correction from the author and update `<body>` accordingly. Re-render the combined preview and repeat this question.
  - "Change something else" — second-level AskUserQuestion (multiSelect): which of — Title / Labels / Issue links / Draft or ready for review. For each selected item, take a free-text correction from the author (label corrections still go through the Step 4 verification check; issue-link corrections still go through the Step 2 not-found/already-closed checks; "Draft or ready for review" toggles `<draft-state>` between "Draft" and "Ready for review"). Re-render the combined preview and repeat this question.

Loop has no fixed iteration cap — repeat until the author chooses "Looks good, create it."

### Step 7 — Create PR

```bash
gh pr create \
  --title "<title>" \
  --body "<body>" \
  --assignee @me \
  [--label "<label1>" --label "<label2>" ... for each label in <selected-labels>, omit entirely if empty] \
  [--draft if <draft-state> is "Draft"]
```

Display the PR URL returned by the command.
