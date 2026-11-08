# PR body contract

The PR body that `create-pr` writes and `review-pr` reads. This file is the only definition of its format; the skills point here. The reading side is `scripts/pr-body-parse.jq`; `tests/fixtures/body/` holds its cases.

The writing rules below are for `create-pr`. `review-pr` reads a body through the parser and does not need this file.

## Sections

In this order. Headings are level 2.

| Section | Present |
| --- | --- |
| `## What` | always |
| `## Why` | always |
| `## File risk` | always |
| `## Merge danger` | only when the change is one-way |
| `## Closes` | only when issues are linked |
| `## PR checklist` | only when the repo defines a merge checklist |

## Skeleton

Every section in order. The conditional sections are left out when their condition does not hold. A test reads this block through the parser, so keep it a valid body.

```markdown
## What

<what changed>

## Why

<motivation>

## File risk

### 🔴 Critical

- `<path>` — <short summary of the change>

### 🟡 Medium

### 🟢 Low

- `<path>` — <short summary of the change>
- `<directory or brace pattern>` — <what the group is> (<N> files)

## Merge danger

<justification>

## Closes

Closes #<number>

## PR checklist

- [ ] <checklist item>
```

## What and Why

`## What` summarizes the actual change: what was added, fixed or modified, taken from the diff content and the commit messages together. `## Why` starts at the motivation itself, with no intro sentence and no restating of the title or the What, in 1 to 5 sentences. When no motivation is evident from any source, it says so instead of inventing one.

## File risk

Three subsections, always present, in this order: `### 🔴 Critical`, `### 🟡 Medium`, `### 🟢 Low`. An empty bucket keeps its heading and has no bullets and no placeholder line; one blank line follows it, as after a populated bucket.

Each file, or each group of files, is one bullet:

```markdown
- `<path>` — <short summary of the change>
```

The separator is an em dash. The path keeps its case. The summary has up to 10 words, not counting a group's file count, and describes what changed according to the diff; for a generated file or a pure rename it comes from the numbers, the old path and the other changed files.

A group is files that change together for one reason and share a risk level, inside one directory or one set of siblings (same directory, same base name before the first dot). Its path is a directory (`tests/fixtures/worktree/`) or a brace pattern (`src/app/foo/foo.component.{ts,spec.ts,scss,html}`), and its summary ends with the file count, e.g. `(4 files)`. All members of a group share one bucket; a file with a different risk is its own bullet, and a Critical file or one raised by an open CodeQL alert is never grouped.

## Merge danger

Present only when the change is one-way: reverting the PR does not undo it. The text leads with the irreversible thing and names a concrete change from the diff, for example "Drops column `users.legacy_id` in `db/migrations/0042_drop_users_legacy_id.sql`; reverting the PR won't restore the data." "Risky" alone is not a justification. A two-way change has no section, and the parser reports it as `null`.

## Closes

One line per issue: `Closes #<number>`. No other link form counts (`Fixes`, `Resolves` and lists on one line are not read).

## PR checklist

One unchecked task-list item per checklist row that matches the changed files: `- [ ] <item>`. GitHub renders them as checkboxes; `create-pr` never checks them and never reads their state back. The section is left out entirely when no row matches.

## Deployment PRs

The label `type: deployment` marks a deployment PR. `review-pr` skips it.

## Reading rules

- Section and bucket headings match case-insensitively, with trailing whitespace, not indented.
- The emoji on bucket headings is optional.
- Bullets must match the format above exactly; other lines in File risk are ignored.
- CRLF line endings are accepted.
- Limit: a heading inside a fenced code block is read like any other.
