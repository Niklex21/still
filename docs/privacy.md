# Privacy and data handling

Still has no account, analytics SDK, cloud sync, or application server. Its Swift target has no third-party dependencies. OCR uses Apple Vision; semantic text retrieval uses NaturalLanguage; optional image descriptions use the on-device Apple Foundation Models framework on supported Macs. macOS may separately download its system models. Availability and description quality vary. Pause image analysis in Settings; existing descriptions remain local.

## Local files

By default, Still stores its library in `~/Library/Application Support/Still/`. This includes PNG images, immutable originals, editable annotation bases, OCR text, image descriptions, capture timestamps, source application/window names, notes/tags, walkthrough projects, and upload exports. Preferences use macOS UserDefaults. `STILL_DATA_DIR` can select another library for development.

Files are not encrypted by Still. macOS account permissions and FileVault govern access. Any backup or sync software you run may copy them. Still's Raycast extension reads the same local public library. Sharing, dragging, copying, and explicitly exporting send data to the app or location you choose. Still cannot control destination apps, clipboard history tools, backups, or uploaded copies.

## Private Region

Private captures skip History, persisted metadata, background OCR, and image analysis. They remain usable in the current queue, editor, export dialog, or floating pin. Temporary files are necessary for drag and drop; they live in Still's `Private` directory, rather than its searchable library. After handling and closing the final editor/export/pin, the queue entry is removed from memory and its files are deleted after a short 60-second lease for drag destinations. Quitting or the next startup clears leftover private files. A crash can leave files until the next launch. This is not secure erasure or a promise that pixels only ever exist in RAM.

An explicitly selected Save As location, an image copied to a clipboard, or an upload destination can retain a copy. A private capture cannot become a saved walkthrough. Explicit OCR selection in the editor can recognize text transiently without adding it to searchable History.

## Dismiss, delete, and retention

- **Dismiss / successful use:** remove from the pending queue; ordinary captures remain in History.
- **Close preview:** dismiss the entire pending queue, including the older stack. History and separate pins remain.
- **Delete in History:** move the rendered image, original, and editable annotation bases to macOS Trash and remove their index entry. Trash is recoverable until emptied.
- **Retention:** off by default. Optional 7/30/90-day cleanup moves expired ordinary history captures to Trash. Queued captures, favorites, pins, and saved walkthrough sources are protected. Malformed walkthrough files pause cleanup rather than guessing which sources are safe to remove. Separately exported files are not automatically removed.

## Redaction

Redaction writes opaque pixels into the rendered/exported image. Originals and editable annotation bases are deliberately retained locally for undo and later editing, and can still contain sensitive information. Share the rendered export, not your library or project files. Review OCR/redaction suggestions yourself; detection can miss sensitive content.

## Permissions

Screen recording enables screenshots; it is not continuously recorded. Accessibility enables automatic scrolling only; manual scroll stitching can be used without it. Launch at login is configurable and visible in macOS Login Items. Closing windows leaves menu-bar capture running; use **Quit Still** to stop it.
