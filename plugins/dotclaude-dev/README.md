# dotclaude-dev

Opinionated software-development skills for Claude Code. This file is the one home for how the plugin works, what it needs and where it stops.

## Skills

| Skill | Status | What it does |
| --- | --- | --- |
| `doctor` | stable | Checks the prerequisites below (plugins, CLI tools, the GitHub login, environment variables) and offers to install or enable missing plugins. CLI tools, the login and environment variables are only reported, never fixed. |
| `create-pr` | in development | Creates a pull request for the current branch: one preflight call, then it asks for linked issues and CodeQL alerts, infers labels, title and a body with a per-file risk section, shows one preview and creates the PR with `gh`. |
| `review-pr` | in development | Prepares the review of an open PR created with `create-pr`: an isolated worktree, the PR context (file risk, merge danger, linked issues, CI status, prior feedback) and a listing of the changed files. The review itself (angles, findings, comments) is not implemented yet. |

A skill moves from "in development" to "stable" when a real end-to-end run has passed.

### Arguments

- `create-pr [--issue <numbers or N/A>] [--alert <numbers or N/A>]` — numbers are comma-separated. Given, they replace the two questions for issue numbers and CodeQL alert numbers.
- `review-pr [<pr number or URL>] [<review scope>]` — the scope is a comma-separated list of `pr-review-toolkit` and `plain`. Missing values are asked for.
- `doctor` — no arguments.

## How the skills run

- **Manual only.** All three skills set `disable-model-invocation: true`: you start them yourself (`/dotclaude-dev:create-pr`, `/dotclaude-dev:review-pr`, `/dotclaude-dev:doctor`), the model never starts them on its own.
- **Scripts do the deterministic work.** Everything that needs no judgment (preflight checks, reading a PR, diffs, the checklist, the body check, creating the PR) runs as `bash "${CLAUDE_PLUGIN_ROOT}/scripts/<name>.sh"`. `${CLAUDE_PLUGIN_ROOT}` is replaced by Claude Code in the skill text of an installed plugin.
- **One error contract.** A failing script prints nothing on stdout and one JSON line on stderr: `{error, exit, retryable, what, message}`. The exit codes are 10 (not logged in), 11 (not found or no access), 12 (rate limit), 13 (network), 2 (wrong arguments) and 1 (anything else). The skill stops with the `message`.
- **Testing a checkout.** Start Claude Code with `claude --plugin-dir ./plugins/dotclaude-dev` to run the skills from a working copy instead of the installed version. The script tests run with `npm run test:scripts` in the repository.

### Temporary files

Each run of `create-pr` or `review-pr` works in a new folder under `$TMPDIR/dotclaude-dev` (`/tmp/dotclaude-dev` when `TMPDIR` is not set), named `create-pr-<random>` or `review-pr-<random>`. It holds what the run collected (`preflight.json`, `pr.json`, `body.txt`, diffs, labels and so on). The scripts never delete anything; cleaning the temporary folder is left to the operating system.

## Prerequisites

Run `/dotclaude-dev:doctor` inside the repository you want to use: it checks everything below and offers to fix plugin gaps.

- **Plugins (mandatory):** `superpowers@claude-plugins-official`, `feature-dev@claude-plugins-official`, `pr-review-toolkit@claude-plugins-official`.
- **Plugin (optional):** `ponytail@ponytail`.
- **CLI tools:** `git`, `gh` and `jq`.
- **GitHub login:** `gh` must be logged in on the host of your repository (`gh auth login --hostname <host>`).

### Tool versions

The scripts were tested with git 2.43.0, jq 1.7, gh 2.45.0 and bash 5.2. They are written to also run with jq 1.6 and bash 3.2 (macOS) and an older git, but that is not tested: the `prunable` field of `git worktree list --porcelain` and the field `isCrossRepository` of `gh pr list` are assumptions. The doctor checks that the tools exist, not their versions.

## Known limitations

- **create-pr:** no update mode. When the branch already has an open PR, it stops. It always targets the default branch (no stacked branches or base option), and a PR from a fork would target the fork itself.
- **review-pr:** it does not review PRs from forks, drafts and deployment PRs (`type: deployment`). It only prepares the worktree and the context and lists the changed files.
- **Updates:** a change in the repository reaches an installed plugin only with a new version (the version in `plugin.json`). The installed copy of 0.5.0 holds no scripts, so `claude --plugin-dir` is the way to try newer text.
