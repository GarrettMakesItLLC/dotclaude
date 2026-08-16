---
name: content-drafting
description: Use when writing a blog post, guide, help/docs page, or resource page for MuscleBuddy, NetWorthy, RedThreadEvents, or AdventureOS — turns a brief into a validated MDX draft against @gmi/content's Meta schema, ready for human review. Not for ad creative, social posts, or anything RedThreadEvents' own content-plan pipeline owns.
---

# Content drafting

Turns a `Brief` into an MDX draft (frontmatter + body) for one of the four content pillars
(`blog` / `guide` / `help` / `resource`) that `@gmi/content` already defines, validated against
the real schema before it's handed back. Never auto-commits or publishes — the output is a file
for a human to review.

## Scope

**In scope:** website content — blog posts, evergreen guides, help/docs pages, resource pages —
for any of the four product repos, using `@gmi/content`'s `contentMetaSchema` as the acceptance
contract.

**Out of scope:** ad creative, social captions, video scripts, campaign briefs — that's
RedThreadEvents' `ContentPlan`/`SocialPost` domain, not this skill. If asked for social/ad content,
say so and point at RedThreadEvents instead of drafting it here.

## Inputs

A `Brief` (`platform/packages/content-pipeline`'s `briefSchema`): `topic`, `product`, `kind`,
`audience`, `keyPoints`, optional `cta`/`targetWords`/`tags`. If the caller hands you a loose
request instead of a structured brief, build the `Brief` object first and confirm it captures the
ask before drafting — a vague brief produces a draft that misses the point and wastes the review
pass.

## Process

1. **Load the target product's voice config** — `voiceFor(brief.product)` from
   `@gmi/content-pipeline`. Read `tone`, `readingLevel`, `bannedPhrases`, `brandTerms` before
   writing a word. Every `keyPoints` entry from the brief must be covered somewhere in the body —
   that's the acceptance bar a reviewer will check against.
2. **Write frontmatter matching the target `kind`'s schema** (`blogMetaSchema` /
   `guideMetaSchema` / `helpMetaSchema` / `resourceMetaSchema` in `@gmi/content`). Derive `slug`
   via `deriveSlug`/`slugify` from the title — don't hand-roll slug logic. `date` is today's date
   in the product's content, ISO `YYYY-MM-DD`. Leave `draft: true` unless told otherwise — a
   drafting pass never marks content ready to publish.
3. **Write the body** in the target product's existing content format (MDX matching that repo's
   other posts in `content/blog/` or equivalent — check an existing file in the target repo for
   heading/component conventions before assuming plain Markdown is enough).
4. **Validate**: call `validateDraft({ frontmatter, body, brief })` from `@gmi/content-pipeline`.
   - `schemaErrors` non-empty → fix the frontmatter and re-validate. Never hand back a draft that
     fails schema validation.
   - `voiceWarnings` non-empty → revise the body to remove the banned phrase, or explain to the
     reviewer why it's a false positive (a banned phrase inside a quote, for instance) — don't
     silently ignore it.
5. **Hand back the MDX file plus the `keyPoints` checklist** (which points landed where) so a
   human reviewer isn't re-deriving coverage from scratch.

## What this skill does not do

- Doesn't pick which pillar/topic to write about — that's the brief's job, supplied by whoever
  invoked this skill.
- Doesn't commit, open a PR, or mark anything published. `draft: true` until a human says otherwise.
- Doesn't generate images — `ogImage` is a path the caller supplies if one exists; leave it unset
  otherwise rather than inventing a placeholder.
