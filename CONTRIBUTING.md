# Contributing

This is Garrett's personal Claude Code configuration — hooks, skills, agent
definitions, and conventions he uses across his own repos. It's public so
others can read it, fork it, and adapt pieces for their own setup.

It's maintained solo, in spare time, with no SLA on issues or PRs.

## Reporting a bug or suggesting a change

Open an issue. Include what you expected, what happened, and repro steps if
it's a bug.

## Pull requests

- Fork the repo and branch from `main`.
- Keep the change scoped — one thing per PR.
- Match the existing style (see `CLAUDE.md` and `rules/*.md` for conventions).
- CI must pass. Explain the "why" in the PR description, not just the "what".
- Merges require the maintainer's approval — expect edits or a "thanks, but
  not the direction I want" rather than a merge on every PR.

Large or structural changes (new hook categories, changes to the skill
format) are easier to land if you open an issue first to discuss the
approach before writing code.
