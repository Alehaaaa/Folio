# Checks

Every check runs from the repository root. Three kinds live here.

## Run on every push (`.github/workflows/ios-ipa.yml`)

These guard each release. A red one stops the IPA from reaching AltStore.

- Reader scripts: `app/checks/reader-*.js`
- Source extensions: `test-anna-folio-extension.cjs`, `test-lectulandia-extension.cjs`,
  `test-lectulandia-source-behavior.cjs`, `test-libgen-extension.cjs`,
  `test-open-sources-extensions.cjs`, `test-source-failures-sandbox.cjs`,
  `test-amazon-metadata.cjs`, `check-extension-versions.py`
- Core logic: `test-hardcover-rate-gate.sh`, `test-language-sparse-queue.sh`,
  `test-automatic-epub-ranking.swift`, `test-cloud-sync.sh`,
  `test-localized-edition-title.swift`, `test-html-entities.swift`
- App shape: `test-navigation-root-reset.sh`, `check-dns-coverage.py`

## Live and end-to-end (run by hand on a Mac)

They need a signed Folio.app, a simulator, or real network access:
every `*-e2e.sh`, `test-*-live*.{sh,cjs}`, `test-lectulandia-ios-*`,
`test-encrypted-dns*.sh`, `test-source-job-session.sh`,
`test-alloy-title-*`, `test-lectulandia-queue-actions.sh`,
`test-lectulandia-source-native.sh`, `test-anna-runtime.swift`,
`test-anna-jscore.swift`, `test-extension-browser*.{swift,py}`,
`test-epub-language.swift`, `test-hardcover-status-write-gate.sh`,
`epub-folder-smoke.swift`, `hardcover-auto-match-smoke.swift`,
`folio-package-import-smoke.py`.

## Diagnostics (read-only probes for one problem)

`diagnose-anna-*`, `anna-free-webkit-trace.swift`,
`check-ios-anna-extension-sync.py`, and the fixtures in `anna-fixtures/`,
`anna-integration/` and the separate `goodreads-lab/` app.
