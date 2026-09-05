# Developer experience & agent tooling

The question: **how much of a contributor's (human or agent) time goes to fighting the repo rather than changing it, and where does the repo's own guidance lie?**

## Checklist
- **Cold start.** Time and steps from clone to green typecheck, test, and dev server, following only the written docs (`DEVELOPMENT.md`, `CLAUDE.md`, `bin/doctor.sh`). Every undocumented step, every step that fails, is a finding. Run `doctor` and compare its checks against the prose.
- **Check latency.** Wall time of `typecheck`, `lint`, `test:root`, `build` on this box; the slowest single test files (`vitest --reporter=verbose` durations); a check that takes minutes and blocks every PR is a finding with a number.
- **Agent config accuracy.** Every claim in `CLAUDE.md`, `.claude/rules/*.md`, `.claude/skills/*`, `.claude/hooks/*` that names a path, script, flag, or behavior: verify it exists and does what the text says. Rules whose path-scope glob matches nothing; hooks that never fire or fire on everything (a guard that tokenises a sed argument as file paths is an example); skills that duplicate a rule.
- **Scripts registry.** `package.json` scripts with no docs and docs referencing scripts that don't exist; scripts that need an env var the docs don't mention; `scripts/` files with no `package.json` entry and no importer.
- **Feedback loops.** Can a failing CI job be reproduced locally with one command? Does the failure output name the file? Guards that fail with a generic message.
- **Worktree and multi-agent ergonomics.** `bin/setup-worktree.sh`, the check lock, the claim hook: run each, find the case it mishandles.
- **Generated artifacts.** Every "regenerate with X" block: run X on a clean tree and confirm zero diff. A generator that produces a diff on an unchanged tree is drift or nondeterminism.
- **Dependency hygiene as DX.** Duplicate majors in the lockfile, peer-dep warnings on install, deprecated packages, engines mismatch with what's installed.
- **Editor/IDE.** tsconfig `paths` vs bundler aliases vs vitest aliases — three copies that can disagree; a file that typechecks in CI but errors in the IDE.

## Gates
`doctor` covering every prose setup claim; a docs-pointer test over agent config; a generated-artifact drift job; a check-duration budget test.
