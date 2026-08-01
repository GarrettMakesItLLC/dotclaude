// Conventional Commits, enforced at commit-msg and again on the PR title
// (`.github/workflows/ci.yml`'s `lint-pr-title` job) because merges here are
// squashes — the PR title becomes the commit on `main`, so it is the one
// that has to parse.
module.exports = {
  extends: ['@commitlint/config-conventional'],
  rules: {
    // Scopes are free-form while the workspace layout is still landing; once
    // apps/ and packages/ exist, pin this to the real workspace names.
    'scope-enum': [0],
    'body-max-line-length': [0],
  },
};
