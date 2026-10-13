# Log writing — format, numbering, safety, archival

Load before ANY append to or mutation of `skill-observations/log.md`. Every rule here is mandatory.

## How to Log

Append to the log **silently, within the same turn or the next** — never
batch mentally for later; the act of writing is the enforcement mechanism.

**Mandatory observation checkpoint after every 3rd TodoWrite completion:** After
marking the 3rd, 6th, 9th (etc.) TodoWrite item as completed in a session, you
must **write to the log** — not merely pause to ask yourself a question. Either
append any pending observations, or, if genuinely none have accumulated, append
an explicit acknowledgement marker (a one-line `no observations` note for that
checkpoint). The required action is a concrete log write; a remembered "ask
whether" is not enforcement. This is a hard checkpoint, not a suggestion — the
skill has demonstrated that softer "check when completing items" or "pause and
ask" guidance gets lost during cognitively demanding analytical work, exactly
when the most observations accumulate. The count doesn't need to be precise;
the rule is: roughly every third completion, write to the log (observations or
the acknowledgement marker). The write itself is the enforcement mechanism: it
forces the mental check to surface as a recorded action, and it prevents the
common failure mode where the skill is loaded but no observations are written
until the user explicitly asks.

**Deliverable-event flush:** Hard enforcement that hooks onto tool calls you are
already making is the only reliable mechanism; soft prompts that rely on memory
don't survive cognitive load during long substantive sessions (when the most
insights surface). So tie observation-flushing to deliverable and workflow events
that already involve a tool call. Whenever you present or render a major
deliverable — `present_files`, a deck or PDF render, a staged skill file handed
to the user — or complete a task/todo batch, flush any pending observations to
the log at that moment, before moving on. These are natural, already-occurring
checkpoints; piggy-backing the flush onto them means the write happens as a
side effect of work you were doing anyway, rather than depending on a separate
act of memory.

**Numbering discipline (mandatory, every append):**

1. *Pre-check:* read the actual log and find the highest existing number —
   never trust session memory:

   ```bash
   # GNU grep:
   grep -oP '### Observation \K\d+' log.md | sort -n | tail -1
   # macOS / POSIX:
   grep -o '### Observation [0-9]*' log.md | grep -o '[0-9]*' | sort -n | tail -1
   ```

2. *Pre-write assertion:* immediately before appending, confirm the proposed
   number doesn't already exist:

   ```bash
   PROPOSED=$(( $(grep -oP '### Observation \K\d+' log.md | sort -n | tail -1) + 1 ))
   grep -qE "^### Observation ${PROPOSED}:" log.md && {
     echo "COLLISION on #${PROPOSED}"; exit 1; }
   ```

   If it fires, increment past all existing numbers and re-check (and log a
   meta-observation — it signals a parallel-session collision).

3. *Post-write verification:* after appending, count occurrences of the
   number; if >1, a parallel writer collided between check and write —
   renumber YOUR entry to max+1. Identify your entry from your own append
   operation (capture the file's line count immediately before and after
   your `>>`; your entry starts at the old line count + 1) — do NOT
   re-grep and take the last occurrence, which may be a colliding writer's
   entry appended after yours. After any `sed` renumber, re-read the
   affected line to confirm the substitution actually took effect — a
   line-addressed `s///` whose target shifted finds no match and still
   exits 0. Pre-write catches stale reads; only a post-write check catches
   the race. The pattern for shared logs written by parallel agents is
   check-then-act-then-verify.

**Log-write safety — never let a mutation span entry boundaries:** When
mutating the log programmatically (marking entries ACTIONED/DECLINED,
archiving, renumbering), a greedy or DOTALL pattern over the whole file can
silently swallow everything from one match to EOF. This has happened: a
`.*$` under `re.S` over the multi-entry file captured from one entry's
Status line to end-of-file and overwrote 16 later entries in a single
substitution. The log is shared state across many entries; mutate it one
bounded entry at a time and verify every mutation.

1. **Re-read and merge immediately before any write-back.** Any full-file
   rewrite (archival, renumbering, reassembly from chunks) built from a
   snapshot destroys whatever concurrent sessions appended after that
   snapshot — the write-back succeeds, the victim gets no error, and the
   loss is invisible. This has happened in production: a parallel session's
   write-back erased two entries appended minutes earlier, hours after the
   exact failure mode had been documented. So: take the snapshot, prepare
   the mutation, then — immediately before writing — re-read the live log
   and diff against the snapshot. If new entries appeared, merge them into
   the write-back (or rebuild from the fresh read). Never write back a
   stale snapshot.

2. **Isolate the target entry, or anchor to a single line.** Either split
   the log on `### Observation N:` headers, edit the TARGET entry's chunk in
   isolation, and reassemble — OR, for a status-only edit, use a strictly
   line-anchored multiline substitution that cannot cross a newline, e.g.
   `re.sub(r'(?m)^(\s*-?\s*)\*\*Status:\*\*.*$', ...)` (multiline `^...$`
   bounds the match to one line). NEVER use a DOTALL/greedy pattern across
   the multi-entry file.

3. **Assert a structural invariant against the LIVE pre-write file.** Count
   `### Observation` headers in the live file immediately before writing and
   again after. For a status-only edit the count MUST be unchanged; for
   archival or append it must change by exactly the expected number. The
   baseline must be the live file at write time, NOT your session's earlier
   snapshot — an invariant computed against a stale snapshot validates that
   you wrote what you intended while still destroying what others wrote in
   between. Fail loudly if the count is off.

4. **Keep the pre-write backup.** Copy `skill-observations/log.md` before any programmatic
   mutation. This is what made full recovery trivial when the truncation
   above occurred — it turned a destructive bug into a non-event.

5. **Verify your entries SURVIVED, not just that they were written.** A
   successful append proves nothing an hour later — a concurrent session's
   write-back can silently delete it, and only the destroying session gets
   any signal (none). Before surfacing observations at session end, grep
   the log for every entry number this session wrote and confirm each still
   exists exactly once; re-append any that are missing (with fresh numbers)
   and log a meta-observation about the collision.

Principle: a log shared across many entries must be mutated one bounded
entry at a time; every rewrite must be based on a fresh read, verified by a
structural invariant against the live pre-write file, and backed up. Writers
must verify survival, not just successful writes — in a concurrent erase,
the victim gets no error.

**Format and insertion:** always `### Observation NNN:`, always appended to
the END of the log, never mid-file, never alternative ID formats. One
format, one insertion point. **Every new observation MUST include
`**Status:** OPEN` as its first field — this is mandatory at write time, not
optional.** Reviews classify entries by their Status line; an observation
written without one is invisible to any status-filtered pass and risks being
silently skipped instead of triaged.

```markdown
### Observation [N]: [Short descriptive title]

**Status:** OPEN
**Date:** [date]
**Session context:** [what task was being worked on]
**Skill:** [existing skill name, or "New skill candidate: [working name]"]
**Type:** [open-source | internal]
**Phase/Area:** [which part of the skill or workflow]

**Issue:** [What happened — specific enough to understand weeks later
without the original conversation.]

**Suggested improvement:** [Concrete change. For existing skills, name the
section or rule; for new skills, scope and key components.]

**Principle:** [The generalisable takeaway — the most important field.]
```

**Context preservation:** if an observation depends on session-local data
(uploads, API output), save that context into the workspace first and add a
`**Reference file:**` line — an observation whose evidence dies with the
session is incomplete.

**Confidentiality at logging time:** for `type: open-source` observations,
the Issue/Improvement fields may reference specifics for context, but the
Principle must be fully generalised — no client names, domains, or details
traceable to a real project. Full confidentiality layers for skill
authoring: `references/skill-authoring.md`.

## Referencing Observations

When citing an observation by number — in conversation, in a review report,
or from within another observation — the number must come from the entry's
literal `### Observation N:` header line. Never cite an observation number
that wasn't read from that header.

- **Search-tool line numbers are positional metadata, not IDs.** `grep -n`
  prefixes every match with a line number; when a match lands mid-entry
  (e.g., on a Session context or Principle line rather than the header),
  that line number is NOT the observation number. Resolve to the owning
  header first — scan backwards from the matched line to the nearest
  preceding `### Observation N:` header and take the number from there
  (e.g., an awk backwards-scan, or re-grep for `^### Observation` and pick
  the last header line before the match).
- **Plausibility check (cheap second layer):** before quoting any
  observation number, compare it against the known counter range — the
  highest `### Observation N:` header in the log. A number outside that
  range (e.g., citing #1365 when the log's counter is at #766) is almost
  certainly a line number or other positional artefact misread as an ID.

The general rule: IDs must come from the record's own identifier field,
never from the positional metadata of the search tool that found it.


## Archival on Write

On every log write, first move already-resolved entries to
`skill-observations/archive/log-[YYYY-MM-DD].md` (preserving the log header
in the archive). "Already resolved" is decided by date, read from the file:
a resolved status MUST record its date — `ACTIONED (YYYY-MM-DD) — [what was
done]` / `DECLINED (YYYY-MM-DD) — [reason]` — and archival moves only
entries whose recorded date is before today. Entries resolved today stay in
the active log until the next day, no matter which session resolved them:
the grace period lives in the file, never in session memory, so it holds
across parallel and subsequent sessions. A resolved entry with no readable
date gets today's date added instead of being archived. The active log
keeps its header, status key, all OPEN entries, and the same-day-resolved
ones.

Archival is a read-filter-rewrite — the highest-risk mutation the log
undergoes, and the one that has destroyed concurrent appends in production.
It MUST follow the full Log-write safety sequence above: backup, re-read
the live log immediately before writing back and merge any entries that
appeared since the snapshot, then verify the post-write header count equals
the live pre-write count minus exactly the number of archived entries.

## Log Structure

```markdown
# Skill Observation Log

Observations captured during task-oriented work.

**Status key:** OPEN = not yet actioned | ACTIONED (YYYY-MM-DD) = skill
updated/created | DECLINED (YYYY-MM-DD) = user decided not to pursue —
resolved statuses always carry their resolution date

---

## [Date]

### Observation 1: [Title]
**Status:** OPEN
[... full format ...]
```
