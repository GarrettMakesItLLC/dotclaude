# templates/obsidian

The starter `.obsidian` config `bin/kb-sync.sh` drops into a freshly created
vault. Copied **once, on first run only** — the script never overwrites
`.obsidian` if it already exists, so anything tweaked later in the app
(pinned tabs, workspace layout, hotkeys) survives every refresh.

Deliberately minimal: no community plugins (`community-plugins.json` is
`[]`) since those need a manual install from inside Obsidian and can't be
assumed present on a machine that has never opened it before.

- `app.json` — link/attachment behavior; keeps wiki-links pointed at their
  target when a note moves.
- `appearance.json` — follows the OS theme (matches Windows light/dark) and
  a slightly larger base font for a mostly-technical-notes vault.
- `core-plugins.json` — enables the built-in plugins the vault actually
  needs to browse and navigate (file explorer, search, graph, backlinks,
  outline) — nothing exotic.
- `community-plugins.json` — empty; see above.
- `graph.json` — starter graph-view settings: colors memory notes and repo
  docs as two groups so the graph reads at a glance, widens link distance so
  a few hundred notes don't clump into an unreadable ball.

`app.json`/`appearance.json`/`graph.json` carry a `"_comment"` key explaining
themselves in place — Obsidian ignores unknown keys in these files.
`core-plugins.json` and `community-plugins.json` are plain arrays (that's
Obsidian's on-disk format) so their comments live here instead.
