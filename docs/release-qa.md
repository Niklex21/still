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
