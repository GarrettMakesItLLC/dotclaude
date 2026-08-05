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
