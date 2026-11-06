# How Still works

## Source map

The product is called Still. Internal Swift modules retain their earlier `SnapShelf` names; these are implementation names, not separate apps.

| Location | Responsibility |
| --- | --- |
| `Sources/SnapShelf/main.swift` | Menu-bar lifecycle, windows, capture commands, login launch, and URL routing |
| `Sources/SnapShelf/Store.swift` | Library persistence, queue actions, image files, OCR scheduling, visual indexing, and search updates |
| `Sources/SnapShelf/Views.swift` and `LibraryView.swift` | Shelf previews, hover actions, History, filters, and selection |
| `Sources/SnapShelf/ShelfInteraction.swift` | Hover/scroll settling, unread timing, expansion, and drag state |
| `Sources/SnapShelf/Editor.swift` | Annotation canvas, selection, crop, OCR selection, and redaction review |
| `Sources/SnapShelf/ScrollCapture.swift` | Region selection, frame capture, and scrolling-session controls |
| `Sources/SnapShelf/PinnedCapture.swift` and `PanelPlacement.swift` | Floating screenshots and remembered display positions |
| `Sources/SnapShelf/VisualSearch.swift` | Availability checks and sequential local vision inference |
| `Sources/SnapShelf/DescriptionView.swift` | Generated description, metadata, notes, tags, and source URL |
| `Sources/SnapShelf/ExportView.swift` and `WalkthroughView.swift` | Sized image exports, editable batch projects, comparison, and composition |
| `Sources/SnapShelfCore/` | Codable models, image processing, stitching, export options, search, shortcuts, and layout calculations |
| `Tests/SnapShelfCoreTests/` | Core regression tests |
| `Sources/SnapShelf/*SelfTest.swift` | Native integration and model checks with isolated libraries |
| `Raycast/src/` | Optional TypeScript launcher extension |
| `Resources/` and `scripts/` | Icon, app metadata, packaging, and synthetic fixtures |

## Capture to history

A capture command hides Still's visible capture-related windows, then invokes native macOS capture. Window captures can be framed against wallpaper or another configured background before entering the store. Scrolling capture collects overlapping frames and feeds them to the vertical stitcher. The stitcher rejects unrelated frames and limits total image size.

`CaptureStore.add` writes an original and a rendered PNG, inserts a `Capture`, and atomically saves the JSON index. OCR runs on a utility queue; optional image understanding runs sequentially through an actor. Captures are available for preview and drag while metadata is being generated.

## Queue state is separate from storage

A capture can exist in History without being queued, unread, or pinned. The main state fields are:

- `onShelf`: membership in the pending queue.
- `inPreview`: membership in the current group of at most three separate previews.
- `reviewedAt`: whether it has received attention.
- `pinnedAt`: an independent floating screenshot.

Removing a current preview does not promote an older queued screenshot. Successful drops consume queue membership; canceled drops do not. Viewing an image can clear its unread state while leaving it queued. Manual shelf presentation stays open until dismissed; automatic previews have separate hover/collapse behavior.

## Editable documents and rendered exports

A saved edit has three layers: the original capture, an editable base image plus an `EditDocument`, and a rendered PNG. The document records annotation identities, geometry, colors, labels/numbers, and an optional crop. Reopening loads that base and reconstructs objects; it does not draw existing marks onto an already flattened export.

Each save writes a new immutable base before committing the new index. A failed index write restores the previous rendered PNG and removes the unsuccessful base. A successful save can retire the preceding base. Session undo/redo keeps canvas states in memory; undo history itself is not persisted across editor sessions.

Copy, drag, OCR after editing, image descriptions, and public image exports use rendered pixels. Redaction therefore affects those outputs, but originals and editable bases remain local source data. PNG/JPEG/HEIC exports contain rasterized pixels rather than the editable document. Walkthrough projects reference captures by ID and retain step ordering, captions, layout, and comparison position.

## Retrieval

Literal search combines title, OCR, valid visual descriptions/tags, and user/source metadata. Smart Search also uses Apple's English `NLEmbedding` sentence vectors. Captions and short OCR chunks are embedded separately so a long page does not drown out a useful visual description. Exact matches retain priority; semantic results are ranked by cosine similarity. Cached vectors are keyed by searchable content, so metadata and revision changes invalidate them.

Vision OCR provides words and their pixel bounds. Foundation Models image understanding is guarded by OS and runtime availability checks, uses a bounded image preview, and has no remote provider. Each result carries the capture revision. The store discards stale responses after edits, deletion, cancellation, or paused analysis. Failed descriptions leave OCR and normal capture actions available.

## Raycast and app commands

Raycast reads `library.json` and its rendered images. For semantic results it runs:

```sh
/Applications/Still.app/Contents/MacOS/Still --search-json 'your query'
```

The command emits an ordered JSON array of capture IDs and does not start the app UI. Raycast falls back to literal matching if native search fails.

State-changing actions use the registered `still://` scheme. Routes include `capture`, `search`, `edit`, `text`, `export`, `describe`, `review`, `consume`, `upload`, and `shelf`. IDs identify existing local captures; capture mode uses `region`, `window`, `screen`, or `scrolling`. For example:

```text
still://capture?mode=region
still://search?q=blue%20chart
still://edit?id=<capture-uuid>
```

The app serializes mutations instead of letting the extension rewrite the library. Preparing an upload only exports/copies a local file path; it does not interact with a website's upload API.

## Build identity

`scripts/build.sh` assembles the SwiftPM executable into a normal menu-bar `.app`, generates icon sizes, includes the extension source and README, and signs it. It defaults to ad-hoc signing. `STILL_SIGNING_IDENTITY` selects a stable local identity. The bundle identifier is kept stable to preserve existing users' preferences and screen-capture permission continuity.

The repository excludes packaged apps, dependency directories, local libraries, credentials, and signing material. No developer certificate or private key is needed to inspect or build the source.
