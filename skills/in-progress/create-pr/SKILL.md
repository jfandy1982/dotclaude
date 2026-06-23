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
git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null
```

If no output → stop:

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

**Precondition 3 — Default-branch guard**

```bash
DEFAULT=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')
```

If current branch == `<DEFAULT>` → stop:

> "Branch `<branch>` is the default branch — create a feature branch first, then re-run `/create-pr`."

Store `<DEFAULT>` for reuse in later steps — do not call `gh repo view` again.

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
- Success → display:
  > "Authenticated with `<host>`. Assignee of new PR will be: `<username>`"

Continue without asking for confirmation.

## Mode Detection

```bash
BRANCH=$(git branch --show-current)
gh pr list --head "$BRANCH" --state open --json number,title
```

- Open PR found → **update mode is the only path**. (not yet implemented — stop with: "Update mode is not yet implemented.")
- No open PR found → proceed to create flow.

## Create Flow

Run these steps in this exact order.

### Step 1 — Gather branch context

```bash
git branch --show-current
git log <DEFAULT>..HEAD
git diff <DEFAULT>..HEAD --name-only
git diff <DEFAULT>..HEAD
```

Read the branch name, the commit messages, the list of changed files, and the actual diff content together. Later steps (label inference, PR title, body sections, file risk) all reason from this combined context — do not re-run these commands per step.

### Step 2 — Issue linking

Ask the author for issue numbers via a plain text prompt: "Issue number(s) this PR closes? (comma-separated, e.g. 38, 42 — or N/A) Remark: Issues have to exist in THIS repository."

For each number provided:

```bash
gh issue view <N> --json title,body,labels
```

- Not found → use the AskUserQuestion tool to warn and ask the author to correct or drop it. Not a hard block.
- Already closed → use the AskUserQuestion tool to warn ("Issue #N is already closed — still include?") with options "Include anyway" / "Drop it". Not a hard block.
- Found → fetch title + first paragraph of the issue description + labels.

Use the AskUserQuestion tool to show a confirmation listing each issue number with its fetched title:

- Question: "Confirm linked issues:"
- Options:
  - "Use these issues" (Recommended) — preview: each issue number with its fetched title
  - "Edit" — author revises the issue number list via a follow-up plain text prompt

Format as individual `Closes #N` lines. If `N/A`, store as empty.

Store the result as `<closes>` and the fetched issue summaries (including each issue's labels) as `<issue-context>`. Subsequent steps (file risk, label inference, PR title, body) all use `<issue-context>` as additional signal alongside the branch context from Step 1 — do not re-fetch issues per step.

### Step 3 — File risk

Using the changed files list from Step 1 and `<issue-context>` from Step 2, classify each file:

| Risk | File characteristics |
| --- | --- |
| **Critical** | Auth/security logic, core business rules, data models, DB migrations |
| **Medium** | Service methods, DTOs, state management, API contracts, CI/CD workflows (`.github/workflows/*`); default for unrecognized files |
| **Low** | Tests, renaming, styling/templates, README, config files |

Classify by what actually changed in the diff, not just the file name — e.g. a one-line version bump in a lockfile or config file stays Low/Medium as appropriate, while a substantial change to the same file may warrant a higher classification.

When in doubt, classify up rather than down.

Build a draft with one subsection per risk level, in order Critical → Medium → Low. Omit a subsection entirely if no file falls into that risk level. Files within a subsection are sorted alphabetically by path. Each file gets a one-line annotation (≤10 words) summarizing what changed in that file, derived from the diff content gathered in Step 1:

```markdown
## File risk

### 🔴 Critical

- `<path>` — <short summary of the change>
- `<path>` — <short summary of the change>

### 🟡 Medium

- `<path>` — <short summary of the change>

### 🟢 Low

- `<path>` — <short summary of the change>
```

Use the AskUserQuestion tool to present the draft and ask the author to confirm or edit it:

- Question: "Confirm the file risk sections:"
- Options:
  - "Use derived sections" (Recommended) — preview: the rendered `## File risk` markdown
  - "Edit" — author provides corrections in a follow-up plain text prompt

Store the confirmed sections as `<file-risk>` — appended to `<body>` once the body is assembled in Step 6.

### Step 4 — Label selection

```bash
gh label list --json name --limit 30
```

**Taxonomy detection:** Filter results to labels with `type:` or `aspect:` prefixes.

- If matching labels exist → use only those. Suppress all other labels (`priority:`, `status:`, community labels).
- If no `type:`/`aspect:` labels exist → use all repo labels unfiltered. Skip the enforcement rules below — suggest the most appropriate label from what is available, no minimum-selection required.

**Inference:** From the branch context gathered in Step 1 (commit messages, branch name, changed files, diff) and `<issue-context>` from Step 2, infer a suggested `type:` label. Conventional commit prefixes are the primary signal (`fix:` → `type: bug`, `feat:` → `type: enhancement`, `chore:` → `type: chore`, `docs:` → `type: documentation`, `refactor:` → `type: refactor`); changed files, diff content, and any linked issue reinforce or override when the prefix signal is weak or absent. If a linked issue already carries a `type:` label (from `<issue-context>`) that exists in the fetched label list, treat it as a strong signal — prefer it over a weak/absent prefix signal, and surface it alongside the prefix-derived guess if the two disagree so the author can pick. If no clear signal, no `type:` label is inferred.

If a linked issue carries an `aspect:` label (from `<issue-context>`) that exists in the fetched label list, infer it as the suggested `aspect:` label for Sub-step 4b. No other `aspect:` inference is attempted — without a linked issue carrying one, no `aspect:` label is inferred.

#### Sub-step 4a — `type:` label

Use the AskUserQuestion tool to ask:

- Question: "`type:` label for this PR:"
- Options:
  - "Use recommended: `<inferred-label>`" (Recommended, only shown if a label was inferred) — proceeds with the inferred label only
  - "Add to recommended" (only shown if a label was inferred) — keeps the inferred label, then prompts for additional `type:` labels via free text
  - "Choose manually" — discards any inferred label, lists all `type:` labels from the fetched list, then prompts for `type:` label(s) via free text
  - "Skip" — no `type:` label selected

If no label could be inferred, skip straight to listing all `type:` labels from the fetched list and prompt the author to provide a label directly, with "Skip" still available — no recommendation option shown.

#### Sub-step 4b — `aspect:` label

Use the AskUserQuestion tool to ask:

- Question: "`aspect:` label for this PR (optional):"
- Options:
  - "Use recommended: `<inferred-aspect-label>`" (Recommended, only shown if an `aspect:` label was inferred from a linked issue) — proceeds with the inferred label only
  - "Choose manually" — discards any inferred label, lists all `aspect:` labels from the fetched list, then prompts for `aspect:` label(s) via free text
  - "Skip" (Recommended if no label was inferred) — no `aspect:` label selected

No inference is attempted from branch context — too context-dependent to guess reliably. An `aspect:` label is only suggested when a linked issue already carries one.

#### Verification

Verify each manually typed label name (from either sub-step) against the fetched label list (exact match). If a name doesn't match any existing label, warn the author and ask them to correct it or drop it — don't pass unknown label names to `gh pr create`.

**Enforcement** (standard mode only — skip if in fallback mode above):

- If no `type:` label was selected, warn the author but do not block — labels can be adjusted on the PR afterward.
- `type: deployment` cannot be combined with any other `type:` label. If selected alongside another type, warn and ask the author to resolve the conflict before proceeding.

Store the final label set as `<selected-labels>`.

### Step 5 — PR title

Derive the title from the branch context gathered in Step 1 (commit messages, branch name, changed files, diff) and `<issue-context>` from Step 2 — do not re-run `git branch`/`git log`/`git diff`. All sources are weighted equally; none takes precedence by default.

Determine the dominant conventional commit type and summary by weighing all signals together — commit message(s) (whether one or many), commit prefix counts, what the changed files and diff content actually show, and any type/slug/qualifier embedded in the branch name. No single signal automatically wins (e.g. a single substantial `feat:` commit alongside several trivial `chore:` commits should not lose to `chore:` on count alone; extra details from the branch name could provide additional context, when present). Construct `<type>: <summary>`.

No clear dominant type even after weighing all signals → fall back to the `type:` label from `<selected-labels>` (Step 4) as the type prefix. If no `type:` label was selected either, ask the author to provide the title.

Use the AskUserQuestion tool to present the derived title and ask the author to confirm or edit it:

- Question: "Confirm the PR title:"
- Options:
  - The derived title (if it matches conventional commit format — mark as Recommended)
  - "Edit" — author will provide their own title in a follow-up plain text prompt

After the author confirms or provides a title, validate against conventional commit format (`<type>(<optional scope>): <description>`). If it does not match, use AskUserQuestion again to warn and offer:

- Options:
  - A suggested corrected title (Recommended)
  - "Edit" — author provides another title in a follow-up plain text prompt
  - "Use as-is" — author acknowledges the format violation and proceeds anyway

Repeat validation on every new title the author provides. Only exit the loop when the title is valid or the author explicitly chooses "Use as-is".

Store confirmed title as `<title>`.

### Step 6 — PR description (body)

Derive a combined "What" and "Why" from the branch context gathered in Step 1 (commit messages, branch name, changed files, diff) and `<issue-context>` from Step 2 — do not re-run `git log`/`git diff`:

- **What** — summarize the actual change: what was added, fixed, or modified. Derived from the diff content and commit messages together, not just commit messages alone.
- **Why** — summarize the motivation. If issue(s) were linked in Step 2, derive Why primarily from the fetched issue description(s). Otherwise, derive from commit messages (e.g. references to a bug, a goal stated in a commit body). If no motivation is evident from either source, state that explicitly rather than inventing one.

Use the AskUserQuestion tool to present the draft and ask the author to confirm or edit it:

- Question: "Confirm the PR body (What & Why):"
- Options:
  - The derived draft (Recommended)
  - "Edit" — author provides their own text in a follow-up plain text prompt

Assemble `<body>` as the confirmed What/Why text, followed by `<file-risk>` from Step 3, followed by a `## Closes` section built from `<closes>`. Omit the `## Closes` section entirely if `<closes>` is empty.

### Step 7 — Draft or ready for review

Use the AskUserQuestion tool to ask:

- Question: "Is the PR ready for review or should it be created in draft state?"
- Options:
  - "Ready for review (Recommended)" — PR is visible and reviewers can be requested
  - "Draft" — PR is open but marked as work in progress

Wait for the user's answer before proceeding.

### Step 8 — Final preview

Present the fully assembled PR exactly as it will be created — title, complete `<body>` (What/Why + File risk + Closes sections together), `<selected-labels>`, assignee, and draft/ready state — in one combined preview.

Use the AskUserQuestion tool to ask:

- Question: "Create this PR?"
- Options:
  - "Yes" (Recommended) — preview: the full assembled PR (title + body + labels + state)
  - "No" — stop without creating the PR

Stop without running `gh pr create` if the answer is "No".

### Step 9 — Create PR

```bash
gh pr create \
  --title "<title>" \
  --body "<body>" \
  --assignee @me \
  [--label "<label1>" --label "<label2>" ... for each label in <selected-labels>, omit entirely if empty] \
  [--draft if chosen]
```

Display the PR URL returned by the command.
