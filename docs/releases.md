# Building a downloadable Mac app

The DMG contains one self-contained `Still.app` and an Applications shortcut. Users open the disk image and drag Still into Applications. They do not need Xcode, Swift, Node.js, or a package manager to run the native app. Raycast remains optional.

## Preview package

On a Mac with the Xcode 27 SDK:

```sh
STILL_RELEASE_LABEL=1.0.0-preview.1 ./scripts/package-dmg.sh
```

This builds both **arm64 and x86_64** slices and produces:

```text
dist/Still-1.0.0-preview.1-universal.dmg
dist/Still-1.0.0-preview.1-universal.dmg.sha256
```

An eligible Apple Silicon Mac is still required for Apple Intelligence image descriptions. The native screenshot/OCR/editor features have their separate OS requirements listed in the README. Universal packaging does not make the optional vision model available on Intel.

The default is **ad-hoc signed and not notarized**. macOS may block opening a downloaded preview because the developer cannot be verified. This is distinct from the per-user screen-capture permission requested by the app. See [Apple's explanation of safely opening apps](https://support.apple.com/en-us/102445). Do not describe a preview package as Apple-approved or notarized.

`STILL_ARCHS=arm64` or `STILL_ARCHS=x86_64` produces a single-architecture package instead. `STILL_RELEASE_LABEL` controls the filename, while the app's version comes from `Resources/Info.plist`.

## Developer ID signing and notarization

For normal distribution outside the App Store, use a **Developer ID Application** certificate and Apple's notary service. An **Apple Development** certificate is a different identity and cannot replace Developer ID for this process.

After configuring a notarytool keychain profile on the build machine, run:

```sh
STILL_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
STILL_NOTARY_PROFILE="your-notary-profile" \
STILL_RELEASE_LABEL=1.0.0 \
./scripts/package-dmg.sh
```

The build enables the hardened runtime and a secure signing timestamp for a named Developer ID identity. Packaging submits the app, staples its ticket, assembles the DMG, then signs, submits, and staples the disk image. Credentials remain in the local keychain; do not commit certificates, private keys, or passwords.

Apple documents the full requirements in [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) and [Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution).

## Check the deliverable

The script verifies the code signature and DMG integrity, and writes a SHA-256 checksum. Before uploading, also:

1. Mount the DMG read-only and confirm its top-level contents are `Still.app` and the Applications shortcut.
2. Check `lipo -archs` on the app executable; a universal package must report both `arm64` and `x86_64`.
3. Run the native self-test on the mounted app in an isolated test session. Running the executable directly validates app contents; it does not simulate a browser download's Gatekeeper check.
4. For a notarized release, validate both stapled tickets and assess the app with Gatekeeper. Test a real browser download on a clean Mac before claiming a smooth first launch.
5. Verify the bundle contains no local libraries, screenshots, signing material, or developer-specific paths.

The Intel slice can be cross-compiled on Apple Silicon, but building it is not proof that it has run on Intel hardware. State which hardware was actually tested.

## Publish on GitHub

Commit the release tooling and documentation first, and attach the DMG and checksum to a release at that commit. For example, using GitHub CLI:

```sh
gh release create v1.0.0-preview.1 \
  dist/Still-1.0.0-preview.1-universal.dmg \
  dist/Still-1.0.0-preview.1-universal.dmg.sha256 \
  --repo Niklex21/still \
  --prerelease \
  --title "Still 1.0.0 preview 1" \
  --notes-file /path/to/release-notes.md
```

Preview release notes should explicitly state the signing/notarization status, macOS requirements, optional model requirements, tested architecture, and installation steps. GitHub's source-code ZIP/TAR downloads contain source; the separately attached `.dmg` is the runnable app download.
