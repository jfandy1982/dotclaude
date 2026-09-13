---
name: doctor
description: Checks dotclaude's plugin, CLI tool, and environment-variable prerequisites; offers to fix plugin gaps.
disable-model-invocation: true
---

# doctor

Checks the local Claude Code environment: required plugins, CLI tools, environment variables. Read-only and safe to repeat. Plugins are fixed only with confirmation; CLI tools and env vars are report-only, never fixed.

Three passes, run in order, never interleaved: **Check** (Step 1) → **Fix** (Step 2) → **Report** (Step 3). Every check runs to completion regardless of earlier results.

Each invocation is independent: re-run every Step 1 check live, even if this skill already ran earlier in this conversation. Never reuse a status, outcome, or report from a previous invocation.

## Step 1 — Check pass

Run every check below and store each result before moving to Step 2. No fixing yet, no output yet.

**Plugins** — run `claude plugin list --json` once and reuse its output for every plugin below (never once per plugin). It returns a JSON array of objects with an `id` and a boolean `enabled`. Look up each `id`: absent → `missing`; present with `enabled: true` → `enabled`; present with `enabled: false` → `disabled`.

| Plugin | Category |
| --- | --- |
| `dotclaude@jfandy1982-dotclaude` | self |
| `superpowers@claude-plugins-official` | mandatory |
| `feature-dev@claude-plugins-official` | mandatory |
| `pr-review-toolkit@claude-plugins-official` | mandatory |
| `ponytail@ponytail` | optional |

`dotclaude` can only ever resolve to `enabled` — if this skill is running, its own plugin is installed and enabled.

**CLI tools** — `command -v <tool>`, one invocation per tool. Each is `present` or `missing`, and mandatory.

| Tool |
| --- |
| `git` |
| `gh` |
| `jq` |

**Environment variables** — none currently required. Add rows here (checked with `[ -n "${VAR:-}" ]`, always optional) when a shipped skill hard-gates on one.

## Step 2 — Fix pass (ask-first)

Act on the statuses stored in Step 1 — never re-run a check here. Plugins with status `disabled` or `missing` need a fix; `dotclaude` is excluded entirely. CLI tools and environment variables are never fixed, only reported. If nothing needs a fix, skip this step.

Ask in two rounds, mandatory plugins first, then optional — one `AskUserQuestion` call per round, one question per plugin. Skip a round whose category has nothing to fix. `AskUserQuestion` accepts at most 4 questions, so split a category with more than 4 into successive calls.

Per plugin, the question is "`<plugin>` is not installed. Install it?" (options "Install" / "Skip") when `missing`, or "`<plugin>` is disabled. Enable it?" (options "Enable" / "Skip") when `disabled`.

Then, for each confirmed plugin, run via the Bash tool — always with `--json`, never plain, never piped:

- `missing` → `claude plugin install <plugin> --yes --json`
- `disabled` → `claude plugin enable <plugin> --json`

Ignore the exit code; it is unreliable for both commands. Parse the JSON's `outcome` field instead: `"ok"` records `fixed`, anything else records `fix-failed` and surfaces the JSON's `message` verbatim. A plugin left unconfirmed records `skipped` and runs no command.

## Step 3 — Report pass

Render exactly once, after Steps 1 and 2 are both complete. One line per check, grouped by category, with ✔/✘ markers.

An item passes when: `dotclaude` — always; a mandatory plugin — Step 1 said `enabled`, or Step 2 recorded `fixed`; a CLI tool — `present`. Optional plugins and env vars never affect the overall pass, but a non-clean state is always surfaced.

If every mandatory plugin, `dotclaude`, and every CLI tool pass, print:

> "All mandatory prerequisites for using the dotclaude plugin are set up."

followed — only when an optional plugin or env var is not clean (`disabled`/`missing`/`skipped`/`fix-failed`) — by one line per non-clean optional item:

> Optional gaps:
>
> - `<plugin-or-var>` — `<state>`

Omit that block entirely when every optional item is clean. Otherwise, show the full itemized breakdown across all categories, including any `fix-failed` message from Step 2.

## Maintenance

The lists above are hardcoded here — no external config, no discovery from other skills. When a new skill needs a CLI tool or environment variable, or your plugin habits change, edit the tables by hand and put anything belonging to an optional skill in the optional category.
