# Contributing to Still

Still favors a small native UI, fast capture actions, reversible editing, and local data. Issues and pull requests are welcome.

## Get started

Follow the build instructions in [README.md](README.md). Use Xcode 27's SDK for the full app. The Swift package has no external dependencies; the optional Raycast extension installs its JavaScript dependencies with `npm ci`.

Use `STILL_DATA_DIR` with a fresh temporary directory for demos and manual experiments. Do not run `--demo` against your everyday library. Native self-tests already use isolated stores.

The source map and persistence boundaries are described in [docs/architecture.md](docs/architecture.md).

## Changes worth preserving

- Keep queue membership, current previews, viewed state, and floating pins separate.
- Do not consume a queue item until a drag or save actually succeeds.
- Preserve original pixels and editable objects when changing annotation behavior.
- Never let stale OCR/model results overwrite a newer capture revision.
- Keep Raycast mutations routed through the app rather than writing the index from both processes.
- Keep capture data local. Any proposed remote integration should be explicit and optional.
- Avoid adding permanent panels, noisy controls, or hover-driven resize loops.

## Validation

For core/model/image changes, run the Swift tests documented in the README. For native capture, editor, shelf, clipboard, or window behavior, also run `--self-test` in a logged-in macOS desktop session and exercise the affected UI. Integration tests temporarily register isolated test hotkeys and use a separate named clipboard. Views are rendered offscreen with synthetic data. `./scripts/check.sh` runs the complete automated checks; snapshots appear in `.build/qa-snapshots`.

Run `--visual-search-self-test` for indexing lifecycle changes. Run `--visual-model-test` from the built `dist/Still.app/Contents/MacOS/Still` bundle (it uses its bundled icon fixture). Use it only when a real compatible system model is ready, and state whether a model check ran, skipped, or was unavailable. A passing controlled-analyzer test is not proof that Apple's model responded successfully.

For Raycast changes, run `npm run typecheck`, `npm test`, and `npm run build` from `Raycast/`.

Include the observed behavior and relevant validation in your PR. For a bug report, include the macOS and Xcode versions, steps to reproduce, and whether the issue affects a fresh temporary library. Use synthetic screenshots or redact private information before attaching files. Do not include an actual library, personal screenshot collection, signing identity, token, or certificate.

Contributions are provided under this repository's [MIT license](LICENSE).
