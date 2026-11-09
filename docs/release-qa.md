# Release QA

This matrix separates deterministic checks from desktop behavior that needs a person or a clean interactive Mac. A successful build does not mean every workflow is verified.

## Automated, with synthetic data only

Run `./scripts/check.sh`. It uses temporary libraries and a named clipboard; it does not display app windows or capture the desktop. The native tests need a logged-in macOS session for AppKit and isolated hotkey registration. Some restricted shell sandboxes prevent macOS NSItemProvider from loading its own temporary file; run the test outside that shell sandbox rather than weakening app permissions.

| Area | Coverage |
| --- | --- |
| Images and scrolling | Every-pixel overlap offsets, stitching, orientation, window framing, limits, readable drag-provider files |
| Queue | Current three plus older pending stack; success/cancellation; no backfill; close dismisses all; handled/viewed images do not return on next capture; unread count |
| Interaction | Hover suppression during scroll, stationary stack-edge resize loop, layout exit guard, manual-open persistence, automatic-empty hiding |
| Editor | Editable round trips, crop/revert, undo/redo, opaque redaction + OCR, save rollback, unchanged-save no-op, inline commit/cancel, zoom anchor and Retina pixel scale |
| OCR/search | Real Vision words and positions, source/date/tag filters, literal retrieval, local semantic synonyms when available |
| Visual descriptions | Controlled analyzer: serialized inference, cancel/stale/edit/delete/restart/retry/unavailable handling. Actual model test is a separate opt-in check |
| Sharing | PNG/JPEG/HEIC decoding, dimensions, original preservation, 1× clipboard preset, bounded JPEG file budget |
| Privacy/cleanup | Private metadata never persists; no private background indexing; final-user lease; retention protections; partial Trash rollback and persistence |
| Compare | Identical images, positive/negative translation, changed pixels, ignored regions, asynchronous comparison, wipe UI rendering |
| Rendering | Offscreen synthetic Library, editor, export, privacy/controls, expanded History shelf, Compare snapshots |
| Raycast | TypeScript check, search/filter tests, production CLI build into isolated output, npm audit |
| Distribution | Universal build, strict code signature verification, DMG integrity/checksum; source installer to an isolated destination |

Comparison fits images into the first capture's canvas without stretching. Translation alignment searches up to 10% of each dimension, capped at 100 comparison pixels. It is not image warping or proof of pixel identity: comparison is bounded to a 2000-pixel longest edge, tolerance is adjustable, and translated non-overlapping edges are excluded from the percentage. Ignored rectangles and comparison settings are session-only.

For Apple's real on-device model, run:

```sh
dist/Still.app/Contents/MacOS/Still --visual-model-test
```

This uses generated chart/shape images and the bundled app icon; it does not analyze your library. System Vision OCR or the semantic model may be unavailable on a virtualized CI runner, even after an OCR CPU retry. `--allow-unavailable-model` explicitly logs only the affected model checks as skipped; failed assertions still fail the run. Strict local tests omit this flag and exercise real OCR/redaction retrieval. A controlled-analyzer pass must never be reported as a real inference pass.

## Manual gate before promoting a public release

Do these in an approved desktop session or on a spare Mac. These are **not implied by the automated checks**:

- Fresh browser download, Gatekeeper warning and documented Open Anyway path; first-launch screen permission, rejection/regrant, reinstall with changed ad-hoc signature.
- Region/window/main-screen capture; Esc cancellation; repeat region after display removal; delayed capture/cancel; confirm focus returns to the original app.
- Window wallpaper framing on Retina and external displays; repeat region on displays with negative coordinates.
- Manual and optional automatic scrolling on browser/document content, including sticky headers and reaching the end.
- Capture while all windows are closed; launch at login; shortcut conflicts and custom recording; verify an explicit Quit stops capture.
- Move shelf/pins across displays; stack hover without movement; scroll while hovered; corner buttons and keyboard actions; close/delete semantics in queue versus History.
- Drop into Finder, a message composer, browser upload target, and back into Still; cancel a drag; check a destination can read a private dropped file.
- Upload path helper in an actual file chooser; Copy for Sharing into an app that may re-encode images.
- Editor text field focus, Return/Shift-Return/Esc, zoom/pan/tool shortcuts, clipboard and save/export dialogs; inspect all controls in light/dark mode and Reduce Motion.
- Compare unrelated/different-sized captures, ignore a changing clock, export the highlighted result; walkthrough ordering/captions, PDF and Markdown folders.
- Raycast install/search/preview and native commands; actual Intel execution and the oldest supported macOS on separate hardware/VM when available.

## Current release pass

The release-readiness branch is undergoing these checks. Do not treat this document as a signed-off checklist. Record observed counts, CI run, source commit, DMG checksum, tested OS/architecture, model availability, and remaining manual gates in the PR/release notes. The developer's running app is not replaced during automated testing.

### 2026-11-07 local evidence

On Apple Silicon with macOS/Xcode 27: 38 Swift tests and 177 native checks passed; controlled visual-index lifecycle checks passed; real on-device chart, edited shape, and bundled icon inference passed. Raycast typecheck, five tests, isolated production build, and npm audit passed with zero advisories. The source installer built, verified, and installed into `.build/install-qa` without launching. The first new universal DMG mounted read-only, passed strict signature verification, exposed both architecture slices, and passed the same 177 native checks from its mounted bundle. These counts do not sign off the manual gate above. The final rebuilt artifact and remote CI are recorded in the PR. The expanded strict local suite now includes private walkthrough/cleanup protections, long PDF captions, and CPU OCR.

### Public 1.1 preview 1 transfer test, November 8

On Apple Silicon running macOS 27.0.1, a fresh Chrome profile downloaded the public DMG with quarantine intact. Its SHA-256 matched the published checksum. Gatekeeper blocked the first launch and the user approved Open Anyway. The downloaded app opened with an empty, isolated Still library on an existing macOS account.

A synthetic screenshot went through the public app’s shelf into an empty Finder folder and a Chrome drop target. Both recipients got the original PNG bytes. Hover-⌘C followed by ⌘V in Chrome delivered an 820 × 330 image with identical decoded pixels. Prepare for Upload followed by ⌘⇧G and ⌘V in Chrome’s native file chooser delivered the original PNG bytes to a loopback HTTP server. The successful drag and copy cleared their queue entries and preserved History.

Screen Recording remained denied on a translocated test copy after the user enabled Still and relaunched it. A Finder-installed copy was seen running at /Applications/Still.app, then disappeared twice. The cause was not established. The previous working local build was restored. A successful capture after granting permission to the public DMG on a clean account remains open. Intel, minimum macOS 14, and multi-display desktop QA also remain open.

### Updater and onboarding candidate

A disposable pair of updater-enabled Still apps with an isolated library, bundle ID, and signing key exercised the real Check for Updates action. Sparkle offered build 101 to build 100 from a loopback feed, installed the signed DMG, and relaunched at the same path with build 101. The release-feed verifier accepted the signed archive and rejected a one-byte modification. The production feed’s initial signature was checked against the embedded production public key and the downloaded public build 5 DMG. Build 5 users install the first updater-enabled release manually.

The first-run guide, consent defaults, event payload, lack of a persistent analytics ID, opt-out, and editable issue URL are covered by the packaged native checks. Remote ingestion needs a dedicated Still project. A source-built candidate upgrade on the existing Mac preserved the set of screenshot IDs and the customized shortcut configuration.


The previously approved daily installation had an Apple Development designated requirement. The initial source candidate was ad-hoc signed and failed preflight even with Still’s System Settings switch enabled. Rebuilding with the original personal signing identity satisfied the previous designated requirement. That build replaced the app at the same path, then captured a 750 × 232 private region of the synthetic Chrome card without a new permission prompt. The test preview was consumed. The real history IDs and shortcut configuration were preserved, and one daily Still process remained. This recovery applies to the locally signed installation. Public ad-hoc builds have build-specific identities.
