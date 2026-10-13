# What to watch for

Load when deciding whether something is worth logging.


**Signals for a NEW skill:** a reusable multi-step workflow; a methodology
the user explains that no existing skill captures; a recurring task type
with similar structure; a process with clear inputs, phases, outputs; the
user describing a refined process ("I always do it this way"); a structured
approach emerging naturally during work.

**Signals for IMPROVING an existing skill:** anything from a task that used
a skill and could make it better — problems, positive signals, or neutral
gaps. Examples: the agent violates a documented rule (the skill needs
enforcement, not louder rules); a user correction reveals a missing rule or
edge case; a better workflow emerges than the skill recommends; a technique
works well enough to promote from incidental to recommended; an undocumented
use case; feedback that generalises; a wrong assumption; new tooling
obsoletes a step; corrections forming a pattern; a principle that applies to
other skills too; a naming/framing/structural suggestion, even
conversational.

**Signals for SIMPLIFYING a skill:** a section never relevant across many
sessions; a rule from a single unvalidated observation; workflows users
consistently shortcut; sections loaded but never acted on; contradictory
rules; "just in case" complexity that never triggered; a rule the agent
consistently fails to follow (convert to structural enforcement — checklist,
verification step, unskippable tool call — or remove it). Treat these as a
review checklist; ask "what can we remove?" as deliberately as "what should
we add?"

**Do NOT log:** one-off corrections that don't generalise; preferences
already captured in a skill; tool bugs unrelated to methodology;
observations that would need proprietary client information to be useful in
an open-source skill (unless an internal skill is the right home).
