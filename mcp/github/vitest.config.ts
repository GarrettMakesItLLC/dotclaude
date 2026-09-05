import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // The suite must not inherit the developer's own credentials. Token
    // selection now reads GH_TOKEN/GITHUB_TOKEN (#263), so a box that exports
    // either turned a dozen unrelated tests red — they count `fetch` calls, and
    // an ambient token adds the scope probe. Cleared globally; the tests that
    // are ABOUT selection set them deliberately.
    setupFiles: ["./test/setup.ts"],
  },
});
