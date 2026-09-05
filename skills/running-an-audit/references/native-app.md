# Native app (Capacitor / store wrapper)

The question: **does the wrapper ship the same product the web does, and can it be released and updated without a store rejection?** Product behavior that exists only in the wrapper, or only outside it, is the core finding class.

Shares surfaces with `feature-completeness` (a feature advertised for the app that the wrapper cannot deliver belongs there), `legal-compliance` (store-specific disclosures: account deletion, data safety forms, IAP rules), `security-access-control` (deep-link and intent handling, webview settings), and `web-delivery-performance` (the wrapper's own bundle).

## Checklist

- **The wrapper is a wrapper.** Grep `apps/native/src` and platform dirs for anything that is product logic rather than a platform bridge. Each is a finding: it exists on one platform only.
- **Build inputs.** `capacitor.config.*` server URL / `webDir`; what commit of the web build the last release embedded (`native-release.yml` and its artifacts); whether the release workflow builds from the same sha CI tested.
- **Plugins.** Every Capacitor/Cordova plugin: version vs latest, maintained, permissions it adds to the manifest / Info.plist, and whether the web layer feature-detects it (a plugin call with no web fallback is a crash on web or a silent no-op).
- **Android manifest and iOS Info.plist.** Declared permissions vs used ones (each unused permission is a store-review finding); `usesCleartextTraffic`; `allowBackup`; exported activities; deep-link / app-link verification (`assetlinks.json` / `apple-app-site-association` served with the right content-type and matching the signing cert).
- **Store compliance.** Account deletion reachable in-app (Apple 5.1.1(v), Google policy); privacy nutrition labels / Data safety form vs the actual processor register; IAP: any purchase of digital goods in the wrapper routed around the store's billing is a rejection; login providers (Sign in with Apple requirement when any third-party login is offered on iOS).
- **Version and update posture.** `versionCode`/`build` monotonic in git history; minimum OS versions vs the web bundle's browserslist; a forced-update path when the API drops an old client.
- **Offline and PWA parity.** Service worker behavior inside the webview; push notification registration (FCM/APNs) vs the web push path — one user, two tokens, one delete?
- **Signing and secrets.** Keystore / provisioning references in the repo or workflow; any secret in `apps/native` that is not in the wrapper's own env contract; `google-services.json` committed?
- **Can it be built here?** State plainly which platforms the box can build (per `CLAUDE.md`) and mark the rest *Not verified*.

## Gates that fit this realm

A test that `apps/native/src` imports nothing from `apps/web/src`; a manifest-permission allow-list test; the release workflow asserting the embedded web sha equals the tag's; an `assetlinks.json` / AASA live read-back in the site-hygiene lane; a store-metadata drift check against the processor register.
