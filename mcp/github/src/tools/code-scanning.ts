import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { errorResult, ghPaginate, ghRequest, jsonText, repoParam, resolveRepo } from "../github.js";

/**
 * Code-scanning alert triage (#355, from MuscleBuddy#7676/#7679).
 *
 * The API makes two things easy to get wrong, and both reject the whole call
 * with a 422 rather than doing something sensible:
 *
 *   - `dismissed_comment` is capped at 280 characters. Six of eight dismissals
 *     in #7676 failed on the first attempt for this reason. A written argument
 *     good enough to convince a reviewer does not fit in 280 characters, so
 *     the long form belongs in an issue comment and the dismissal cites it.
 *   - `dismissed_reason` is a CLOSED set, and `used in test code` — the
 *     obvious spelling — is not in it.
 *
 * Both are checked here BEFORE the request, so the caller gets a sentence
 * naming the limit instead of a 422 naming nothing.
 */

/** GitHub's closed set. `used in test code` is the spelling that 422s. */
const DISMISSED_REASONS = ["false positive", "won't fix", "used in tests"] as const;

/** GitHub truncates nothing — over this, the whole request 422s. */
const COMMENT_MAX = 280;

interface RawAlert {
  number: number;
  state: string;
  html_url: string;
  created_at?: string;
  dismissed_reason?: string | null;
  dismissed_comment?: string | null;
  rule?: { id?: string; name?: string; severity?: string; description?: string };
  most_recent_instance?: { location?: { path?: string; start_line?: number } };
}

interface Alert {
  number: number;
  state: string;
  rule: string;
  severity: string;
  path: string;
  line: number | null;
  html_url: string;
  dismissed_reason?: string | null;
}

function shape(a: RawAlert): Alert {
  const loc = a.most_recent_instance?.location;
  return {
    number: a.number,
    state: a.state,
    rule: a.rule?.id ?? a.rule?.name ?? "(unknown rule)",
    severity: a.rule?.severity ?? "(unknown)",
    path: loc?.path ?? "(no location)",
    line: loc?.start_line ?? null,
    html_url: a.html_url,
    ...(a.dismissed_reason ? { dismissed_reason: a.dismissed_reason } : {}),
  };
}

export function registerCodeScanningTools(server: McpServer): void {
  server.registerTool(
    "code_scanning_alerts",
    {
      description:
        "List a repo's code-scanning alerts, shaped to what triage needs: rule id, severity, " +
        "file path and line, and the alert URL. Filter by state and by path prefix. " +
        "Also returns `by_rule`, a count per rule — a family of alerts from one rule is the " +
        "shape that tempts a bulk dismissal, and seeing the count is what makes that a decision.",
      inputSchema: {
        repo: repoParam,
        state: z
          .enum(["open", "closed", "dismissed", "fixed"])
          .default("open")
          .describe("Alert state. Defaults to open, which is what triage looks at."),
        path_prefix: z
          .string()
          .optional()
          .describe(
            "Only alerts whose file path starts with this (e.g. 'apps/server/src'). " +
              "Filtered here rather than by the API, which has no path filter.",
          ),
        limit: z.number().int().positive().max(300).default(100),
      },
    },
    async ({ repo, state, path_prefix, limit }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        const raw = await ghPaginate<RawAlert>(`/repos/${owner}/${name}/code-scanning/alerts`, {
          query: { state },
          limit,
        });
        let alerts = raw.map(shape);
        if (path_prefix) alerts = alerts.filter((a) => a.path.startsWith(path_prefix));
        const by_rule: Record<string, number> = {};
        for (const a of alerts) by_rule[a.rule] = (by_rule[a.rule] ?? 0) + 1;
        return jsonText({ repo: `${owner}/${name}`, state, count: alerts.length, by_rule, alerts });
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "code_scanning_dismiss",
    {
      description:
        "Dismiss ONE code-scanning alert, validating what the API rejects with an unexplained 422: " +
        `the reason must be one of ${DISMISSED_REASONS.map((r) => `"${r}"`).join(", ")} ` +
        `("used in test code" is not one), and the comment is capped at ${COMMENT_MAX} characters. ` +
        "Deliberately one alert per call — bulk-dismissing a rule family is how a real alert gets " +
        "buried among its look-alikes.",
      inputSchema: {
        repo: repoParam,
        number: z.number().int().positive().describe("Alert number (not the rule id)."),
        reason: z.enum(DISMISSED_REASONS).describe("GitHub's closed set of dismissal reasons."),
        comment: z
          .string()
          .optional()
          .describe(
            `Why, in ${COMMENT_MAX} characters or fewer. A longer argument belongs in an issue ` +
              "comment that this one cites — put the issue reference here.",
          ),
      },
    },
    async ({ repo, number, reason, comment }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        // Checked BEFORE the request: the API's 422 names neither the limit
        // nor the field, so the caller learns nothing from it.
        if (comment !== undefined && comment.length > COMMENT_MAX) {
          return errorResult(
            new Error(
              `dismissed_comment is ${comment.length} characters and GitHub caps it at ${COMMENT_MAX} — ` +
                "it rejects the whole call rather than truncating. Put the full argument in an issue " +
                "comment and cite it here (e.g. \"see #1234\").",
            ),
          );
        }
        const alert = await ghRequest<RawAlert>(
          `/repos/${owner}/${name}/code-scanning/alerts/${number}`,
          {
            method: "PATCH",
            body: {
              state: "dismissed",
              dismissed_reason: reason,
              ...(comment !== undefined ? { dismissed_comment: comment } : {}),
            },
          },
        );
        return jsonText({ dismissed: true, ...shape(alert) });
      } catch (err) {
        return errorResult(err);
      }
    },
  );
}
