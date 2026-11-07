# PR body contract

The PR body that `create-pr` writes and `review-pr` reads. Change it here first, then in both skills. The reading side is `scripts/pr-body-parse.jq`; `tests/fixtures/body/` holds its cases.

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

## File risk

Three subsections, always present, in this order: `### 🔴 Critical`, `### 🟡 Medium`, `### 🟢 Low`. An empty bucket keeps its heading and has no bullets.

Each file, or each group of files, is one bullet:

```markdown
- `<path>` — <short summary of the change>
```

The separator is an em dash. The path keeps its case.

A group is files that change together for one reason and share a risk level, inside one directory or one set of siblings (same directory, same base name before the first dot). Its path is a directory (`tests/fixtures/worktree/`) or a brace pattern (`src/app/foo/foo.component.{ts,spec.ts,scss,html}`), and its summary ends with the file count, e.g. `(4 files)`. All members of a group share one bucket; a file with a different risk is its own bullet, and a Critical file or one raised by an open CodeQL alert is never grouped.

## Closes

One line per issue: `Closes #<number>`. No other link form counts (`Fixes`, `Resolves` and lists on one line are not read).

## Deployment PRs

The label `type: deployment` marks a deployment PR. `review-pr` skips it.

## Reading rules

- Section and bucket headings match case-insensitively, with trailing whitespace, not indented.
- The emoji on bucket headings is optional.
- Bullets must match the format above exactly; other lines in File risk are ignored.
- CRLF line endings are accepted.
- Limit: a heading inside a fenced code block is read like any other.
