---
description: Frontend conventions — Next.js/Vite, Tailwind, dark mode, a11y, icons, i18n
paths:
  - "**/*.tsx"
  - "**/*.jsx"
  - "**/components/**"
  - "**/app/**"
---

# Frontend conventions

- **Next.js (App Router)** for new web apps; Vite + React for older / PWA repos. Tailwind for styling.
- Dark mode (`dark:` variants) required on new components.
- WCAG 2.1 AA contrast. Where the repo has a web CI, enforce it with an **axe** (axe-core via Playwright) lane over public + authenticated-mocked routes.
- Lucide icons unless the repo specifies another set.
- In i18n repos: no hardcoded English strings in JSX — use `useTranslations`.
