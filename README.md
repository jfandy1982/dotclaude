# dotclaude

Skills and Agents and Hooks and ... reusable for Claude Code, packaged as plugins. Each plugin lives in its own folder below `plugins/` and is listed in the marketplace of this repository.

## Installation

```
/plugin marketplace add jfandy1982/dotclaude
```

### dotclaude-dev — Opinionated software-development skills for Claude Code

```
/plugin install dotclaude-dev@jfandy1982-dotclaude
```

Skills for pull requests (`create-pr`, `review-pr`) and an environment check (`doctor`). All of them start only when you run them. Run `/dotclaude-dev:doctor` after installing: it checks the prerequisites (a few plugins, `git`, `gh`, `jq` and a GitHub login).

- [`plugins/dotclaude-dev/README.md`](plugins/dotclaude-dev/README.md) — the skills with status and arguments, how they run, prerequisites, known limitations
