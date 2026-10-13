# `/goal` and the goal stop-hook

The `/goal` stop-hook is harness behavior this repo cannot patch. It re-evaluates the goal text against only the recent transcript window, so two kinds of stale verdict appear in long sessions.

## Completed work it cannot see

Merged PRs and closed issues from earlier in the session, especially before a compaction, are outside its window. Against a broad goal sentence it reports "not done" indefinitely, with no way to conclude otherwise (see #237).

**Remedy:** a `/goal` that spans several repos or would outlive one context window is decomposed at the start into GitHub issues, one per named surface or repo. Completion is then checkable by issue state, which survives compaction. If the hook still loops after the tracked work is closed, cite the closed issue numbers in the status report rather than re-arguing the original sentence.

## Phantom background tasks

The hook can report "N background teammate tasks still running" turn after turn, verbatim, after every dispatched agent has finished and merged (see #218). Its background-task check reads a snapshot taken earlier in the session, not live state.

**Remedy:** check `ListAgents`, `TaskOutput(block:false)` and the real PR and issue state. Once those agree the work is done, proceed. The hook repeating a stale claim is not new information.
