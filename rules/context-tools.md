---
description: When to reach for Serena vs. Graphify vs. rg/Read in an app repo
paths:
  - "**/*.ts"
  - "**/*.tsx"
  - "**/*.js"
  - "**/*.jsx"
  - "**/*.py"
  - "**/*.go"
  - "**/*.rs"
---

# Context-graph tools

Applies to app repos (musclebuddy, redthread, etc.), not `dotclaude` itself —
too small and markdown-heavy for either tool to pay off. Install and freshness
mechanics: `integrations.md`'s "Per-project context tools".

- **Default to Serena** for anything symbol-shaped: "where is X defined,"
  "what calls Y," rename/refactor. `find_symbol`, `find_referencing_symbols`,
  `rename_symbol`. Self-indexes live via the language server — no staleness
  to worry about.
- **Reach for Graphify** when the question is relational/architectural: "what
  breaks if I change this," call-graph shape, cross-file impact — the kind of
  question that would otherwise mean several rounds of grep and holding the
  results in context by hand.
- **Fall back to `rg`/`Read`** when neither tool is installed in the repo yet,
  or for anything outside code structure — config values, string content.
- **A zero/empty result from Serena or Graphify is not evidence the thing
  doesn't exist.** Both index declared symbols and extracted code
  relationships — neither has a full-text fallback built in. A naming
  *convention* (e.g. a soft-delete flag pattern), a magic string, or anything
  else that isn't a declared symbol or graph-extracted relationship will come
  back empty even when it's pervasive in the codebase. Before concluding
  something doesn't exist, run one `rg` pass for the plain-language term
  before answering — benchmarked 2026-08-05: both tools missed a real,
  widespread invariant this way, `rg` found it in one pass.
- **Graphify's code nodes cite file-level, not line-level, locations.**
  `graphify explain`/`query` gives you the right file and the call/import
  edges, but not the specific line of the function or constant it names —
  `Read` the file for the exact line before citing one, don't extrapolate it
  from the graph output.
- **Serena resolves the right symbol reliably but drifts on exact line
  ranges** (off-by-one, occasionally tens of lines on a block boundary) —
  benchmarked 2026-08-05 round 2: highest depth of any condition tested, but
  the weakest citation quality. Verify a Serena-reported line number with a
  `Read` before citing it downstream (a PR comment, a refactor patch).
- **A repo's installed PreToolUse hook nudging "MANDATORY: run graphify
  first" is advisory, not a gate** — it's a soft `additionalContext` nudge,
  not a permission deny, regardless of its wording. Round 2 found graphify
  and grep/Read statistically tied overall on a single-lookup question;
  treat the nudge as a hint for relational/architectural questions, not an
  instruction to detour through graphify before every grep or Read.
