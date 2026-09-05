import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  actorLogins,
  labelNames,
  slimBranch,
  slimComment,
  slimIssue,
  slimPr,
} from "../src/slim.js";

/** A GitHub actor as the REST API actually returns it — 18 fields for a login. */
function rawActor(login: string) {
  return {
    login,
    id: 187915592,
    node_id: "U_kgDOCzNdSA",
    avatar_url: `https://avatars.githubusercontent.com/u/187915592?v=4`,
    gravatar_id: "",
    url: `https://api.github.com/users/${login}`,
    html_url: `https://github.com/${login}`,
    followers_url: `https://api.github.com/users/${login}/followers`,
    following_url: `https://api.github.com/users/${login}/following{/other_user}`,
    gists_url: `https://api.github.com/users/${login}/gists{/gist_id}`,
    starred_url: `https://api.github.com/users/${login}/starred{/owner}{/repo}`,
    subscriptions_url: `https://api.github.com/users/${login}/subscriptions`,
    organizations_url: `https://api.github.com/users/${login}/orgs`,
    repos_url: `https://api.github.com/users/${login}/repos`,
    events_url: `https://api.github.com/users/${login}/events{/privacy}`,
    received_events_url: `https://api.github.com/users/${login}/received_events`,
    type: "User",
    site_admin: false,
  };
}

function rawIssue() {
  return {
    url: "https://api.github.com/repos/o/r/issues/55",
    repository_url: "https://api.github.com/repos/o/r",
    labels_url: "https://api.github.com/repos/o/r/issues/55/labels{/name}",
    comments_url: "https://api.github.com/repos/o/r/issues/55/comments",
    events_url: "https://api.github.com/repos/o/r/issues/55/events",
    html_url: "https://github.com/o/r/issues/55",
    id: 5011200620,
    node_id: "I_kwDOSeB_Fc8AAAABKrDabA",
    number: 55,
    title: "Slim the MCP payloads",
    user: rawActor("GarrettMakesIt"),
    labels: [
      {
        id: 11393543258,
        node_id: "LA_kwDOSeB_Fc8AAAACpxusWg",
        url: "https://api.github.com/repos/o/r/labels/status:ready",
        name: "status:ready",
        color: "0e8a16",
        default: false,
        description: "Fully scoped, ready to start",
      },
      {
        id: 11393543556,
        node_id: "LA_kwDOSeB_Fc8AAAACpxuthA",
        url: "https://api.github.com/repos/o/r/labels/type:task",
        name: "type:task",
        color: "bfd4f2",
        default: false,
        description: "Chore / maintenance / non-feature work",
      },
    ],
    state: "open",
    locked: false,
    assignees: [rawActor("GarrettMakesIt")],
    assignee: rawActor("GarrettMakesIt"),
    milestone: { number: 3, title: "v1", creator: rawActor("GarrettMakesIt"), state: "open" },
    comments: 2,
    created_at: "2026-07-29T15:56:50Z",
    updated_at: "2026-07-29T15:56:50Z",
    closed_at: null,
    author_association: "MEMBER",
    active_lock_reason: null,
    sub_issues_summary: { total: 4, completed: 1, percent_completed: 25 },
    body: "## What\nthe body",
    reactions: {
      url: "https://api.github.com/repos/o/r/issues/55/reactions",
      total_count: 0,
      "+1": 0,
      "-1": 0,
    },
    timeline_url: "https://api.github.com/repos/o/r/issues/55/timeline",
    performed_via_github_app: null,
    state_reason: null,
  };
}

/** Every `*_url` key except `html_url` is navigation the caller never follows. */
function urlNoiseKeys(obj: unknown): string[] {
  const found: string[] = [];
  const walk = (v: unknown) => {
    if (Array.isArray(v)) return v.forEach(walk);
    if (!v || typeof v !== "object") return;
    for (const [k, child] of Object.entries(v)) {
      if (k !== "html_url" && (k.endsWith("_url") || k === "url" || k === "node_id")) found.push(k);
      walk(child);
    }
  };
  walk(obj);
  return found;
}

describe("slimIssue", () => {
  it("projects to the fields a caller reads, flattening actors, labels and milestone", () => {
    expect(slimIssue(rawIssue())).toEqual({
      number: 55,
      title: "Slim the MCP payloads",
      state: "open",
      labels: ["status:ready", "type:task"],
      assignees: ["GarrettMakesIt"],
      author: "GarrettMakesIt",
      milestone: "v1",
      comments: 2,
      sub_issues: "1/4",
      created_at: "2026-07-29T15:56:50Z",
      updated_at: "2026-07-29T15:56:50Z",
      html_url: "https://github.com/o/r/issues/55",
    });
  });

  /**
   * The signal that somebody answered an issue's owner-action checklist (#315).
   *
   * Comment author cannot carry it — every agent posts under the owner's
   * account — and enumerating OUTSTANDING actions with `- [ ]` hides an
   * answered issue by construction, since the answered row is exactly the one
   * that does not match.
   */
  describe("owner_action_answered", () => {
    const withBody = (body: string | null) => slimIssue({ ...rawIssue(), body });

    it("is set when a checklist box is ticked", () => {
      expect(withBody("- [x] **Option 1**").owner_action_answered).toBe(true);
      expect(withBody("- [X] shouty").owner_action_answered).toBe(true);
      expect(withBody("* [x] asterisk bullet").owner_action_answered).toBe(true);
      expect(withBody("  - [x] indented").owner_action_answered).toBe(true);
      expect(
        withBody("## ⛔ Owner action required\n\n- [ ] one\n- [x] two\n").owner_action_answered,
      ).toBe(true);
    });

    it("is absent while every box is still open, so it never fires on a fresh issue", () => {
      expect(withBody("- [ ] one\n- [ ] two")).not.toHaveProperty("owner_action_answered");
      expect(withBody("no checklist at all")).not.toHaveProperty("owner_action_answered");
      expect(withBody(null)).not.toHaveProperty("owner_action_answered");
    });

    it("does not fire on prose that merely contains [x]", () => {
      expect(withBody("the array is a[x] here")).not.toHaveProperty("owner_action_answered");
      expect(withBody("see matrix[x][y]")).not.toHaveProperty("owner_action_answered");
    });

    it("rides on a LIST entry, not only a single view", () => {
      // The whole point: an agent scanning a blocked queue never opens the
      // answered one, so the flag has to survive the body being stripped.
      const listed = slimIssue({ ...rawIssue(), body: "- [x] answered" });
      expect(listed).not.toHaveProperty("body");
      expect(listed.owner_action_answered).toBe(true);
    });
  });

  it("omits body by default and includes it on a single-issue view", () => {
    expect(slimIssue(rawIssue())).not.toHaveProperty("body");
    expect(slimIssue(rawIssue(), { body: true }).body).toBe("## What\nthe body");
  });

  it("carries no url/node_id navigation noise through", () => {
    expect(urlNoiseKeys(slimIssue(rawIssue(), { body: true }))).toEqual([]);
  });

  it("cuts the serialized payload by well over 80%", () => {
    const raw = JSON.stringify(rawIssue()).length;
    const slim = JSON.stringify(slimIssue(rawIssue(), { body: true })).length;
    expect(slim / raw).toBeLessThan(0.2);
  });

  it("drops empty collections rather than emitting empty arrays", () => {
    expect(slimIssue({ number: 1, labels: [], assignees: [] })).toEqual({ number: 1 });
  });

  it("marks the PR entries the /issues endpoint mixes in", () => {
    expect(slimIssue({ number: 7, pull_request: { url: "x" } }).is_pull_request).toBe(true);
    expect(slimIssue({ number: 7 })).not.toHaveProperty("is_pull_request");
  });

  it("reports a closed issue's state_reason", () => {
    expect(slimIssue({ number: 1, state: "closed", state_reason: "not_planned" })).toMatchObject({
      state: "closed",
      state_reason: "not_planned",
    });
  });
});

describe("slimPr", () => {
  const raw = {
    number: 54,
    title: "fix: scrub heredocs",
    state: "open",
    draft: false,
    merged: false,
    mergeable: true,
    mergeable_state: "clean",
    head: { ref: "issue-54-x", sha: "abc123", repo: { id: 1, url: "https://api.github.com/x" } },
    base: { ref: "main", repo: { id: 1, url: "https://api.github.com/x" } },
    user: rawActor("GarrettMakesIt"),
    requested_reviewers: [rawActor("someone")],
    labels: [{ id: 1, node_id: "n", url: "u", name: "type:fix" }],
    html_url: "https://github.com/o/r/pull/54",
    created_at: "2026-07-29T00:00:00Z",
    updated_at: "2026-07-29T01:00:00Z",
    body: "PR body",
    _links: { self: { href: "https://api.github.com/x" } },
  };

  it("keeps merge state and refs while dropping the nested repo objects", () => {
    expect(slimPr(raw)).toEqual({
      number: 54,
      title: "fix: scrub heredocs",
      state: "open",
      draft: false,
      merged: false,
      mergeable: true,
      mergeable_state: "clean",
      head: { ref: "issue-54-x", sha: "abc123" },
      base: { ref: "main" },
      labels: ["type:fix"],
      requested_reviewers: ["someone"],
      author: "GarrettMakesIt",
      created_at: "2026-07-29T00:00:00Z",
      updated_at: "2026-07-29T01:00:00Z",
      html_url: "https://github.com/o/r/pull/54",
    });
  });

  it("carries no url/node_id navigation noise through", () => {
    expect(urlNoiseKeys(slimPr(raw, { body: true }))).toEqual([]);
  });

  it("includes body only on a single-PR view", () => {
    expect(slimPr(raw)).not.toHaveProperty("body");
    expect(slimPr(raw, { body: true }).body).toBe("PR body");
  });
});

describe("slimBranch", () => {
  it("keeps name, sha and protection", () => {
    expect(
      slimBranch({
        name: "main",
        protected: true,
        commit: { sha: "deadbeef", url: "https://api.github.com/x" },
      } as Parameters<typeof slimBranch>[0]),
    ).toEqual({ name: "main", sha: "deadbeef", protected: true });
  });
});

describe("slimComment", () => {
  it("confirms where the comment landed without echoing the body back", () => {
    const out = slimComment({
      id: 1,
      html_url: "https://github.com/o/r/issues/55#issuecomment-1",
      created_at: "2026-07-29T00:00:00Z",
    });
    expect(out).toEqual({
      id: 1,
      html_url: "https://github.com/o/r/issues/55#issuecomment-1",
      created_at: "2026-07-29T00:00:00Z",
    });
    expect(out).not.toHaveProperty("body");
  });
});

describe("no tool returns a raw REST payload", () => {
  // `jsonText(data)` was the idiom that dumped the whole API response into
  // context. Banning it keeps a newly-added tool from copying the pattern back
  // in — a projection is not optional, it is the response contract.
  it("never calls jsonText on an unprojected API result", () => {
    const toolsDir = join(fileURLToPath(new URL(".", import.meta.url)), "../src/tools");
    const offenders: string[] = [];
    for (const file of readdirSync(toolsDir).filter((f) => f.endsWith(".ts"))) {
      readFileSync(join(toolsDir, file), "utf8")
        .split("\n")
        .forEach((line, i) => {
          if (/\bjsonText\(\s*(data|raw)\s*\)/.test(line)) {
            offenders.push(`${file}:${i + 1} ${line.trim()}`);
          }
        });
    }
    expect(offenders).toEqual([]);
  });
});

describe("field helpers", () => {
  it("labelNames accepts both label objects and bare name strings", () => {
    expect(labelNames([{ name: "a" }, "b"])).toEqual(["a", "b"]);
    expect(labelNames(null)).toEqual([]);
  });

  it("actorLogins drops actors with no login", () => {
    expect(actorLogins([{ login: "a" }, {}])).toEqual(["a"]);
    expect(actorLogins(undefined)).toEqual([]);
  });

  // A projection is cosmetic. An endpoint answering 200 with an unexpected
  // shape must not turn a write that already succeeded into a failure.
  it("both tolerate a non-array payload instead of throwing", () => {
    expect(labelNames({ number: 8 })).toEqual([]);
    expect(labelNames("nope")).toEqual([]);
    expect(actorLogins({ login: "a" })).toEqual([]);
    expect(labelNames([null, { name: "a" }])).toEqual(["a"]);
  });
});
