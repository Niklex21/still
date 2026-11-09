# Building a downloadable Mac app

The DMG contains one self-contained `Still.app` and an Applications shortcut. Users open the disk image and drag Still into Applications. They do not need Xcode, Swift, Node.js, or a package manager to run the native app. Raycast remains optional.

## Preview package

On a Mac with the Xcode 27 SDK:

```sh
STILL_RELEASE_LABEL=1.1.0-preview.1 ./scripts/package-dmg.sh
```

This builds both **arm64 and x86_64** slices and produces:

```text
dist/Still-1.1.0-preview.1-universal.dmg
dist/Still-1.1.0-preview.1-universal.dmg.sha256
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
STILL_RELEASE_LABEL=1.1.0 \
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

For local development updates, keep the bundle identifier, install path, and Apple Development signing identity consistent. The source installer checks a replacement against the previous development build’s designated requirement. Installing an ad-hoc public preview over that build changes its identity and can require granting Screen Recording again.

The Intel slice can be cross-compiled on Apple Silicon, but building it is not proof that it has run on Intel hardware. State which hardware was actually tested.

## Publish on GitHub

Use one GitHub release per distributed build. Preview tags take the form `vX.Y.Z-preview.N`. Stable tags take the form `vX.Y.Z`. Increment `CFBundleVersion` for each new build and set `CFBundleShortVersionString` to the numeric version. Give fixes a new tag and keep the original DMG downloadable.

1. Select a clean commit on `main` with passing Checks and CodeQL. Build from that commit or use its tested universal CI artifact. If you rename a CI artifact for distribution, regenerate its checksum with the new filename.
2. Prepare the DMG, its SHA-256 checksum, and a build manifest recording the commit, CI run, bundle version and build, architectures, signing status, and DMG hash. Record the verification results and outstanding manual checks in the release notes.
3. Create a **draft** against the full commit SHA. The example below assumes the release files and notes are ready. Set `tag` to the new version being staged.

```sh
tag=v1.1.0-preview.2
commit=$(git rev-parse HEAD)
base="dist/Still-${tag#v}-universal"
gh release create "$tag" "$base.dmg" "$base.dmg.sha256" "$base-build.json" \
  --repo Niklex21/still --target "$commit" --draft --prerelease \
  --title "Still ${tag#v}" --notes-file release-notes.md
```

4. Download the staged assets and verify the checksum. Mount the exact DMG, check its app version and signature, and run the packaged app checks. Record desktop testing against the [release QA checklist](release-qa.md).
5. Publish the reviewed draft with `gh release edit "$tag" --repo Niklex21/still --draft=false`. For a stable release, stage the draft without `--prerelease` and publish it with `--latest`.
6. Confirm the public tag resolves to the tested commit. Update the README download button, release notes link, and source checkout example together. Download the DMG through the public link while signed out and verify its SHA-256 against the published checksum.

## Build from source instead

People who prefer not to trust a prebuilt executable can clone the repository, inspect the native source and build scripts, then run `./scripts/install.sh` with Xcode 27 selected. `STILL_INSTALL_DIR` supports a user-local Applications directory. The script does not use sudo or launch the app. The optional Raycast integration has its own npm dependencies; Swift Package Manager resolves the pinned Sparkle framework for the native app.

Before publishing, record the source commit and actual check results in the release notes, attach the DMG checksum, and complete the [QA matrix](release-qa.md). Do not substitute a passing build for a first-launch/Gatekeeper test.

## In-app updates

Still uses Sparkle starting with bundle build 6. Preview 1 users install their first upgrade from the DMG. Each subsequent build needs a higher numeric bundle build. The menu-bar **Check for Updates…** action reads `docs/appcast.xml` on main. Only advertise published builds that contain the Still update public key. Preview users follow this feed, so promote each entry deliberately.

After publishing the release, run `./scripts/update-feed.sh TAG` on the signing Mac. It downloads the public DMG and checksum, generates a signed feed entry using the dedicated **org.Niklex21.Still.updates** Keychain account, and verifies the signature before replacing the feed. Review the diff and commit it to main with the download-link update. On the previous updater-enabled build, choose **Check for Updates…**, install, and check the relaunched bundle version. Keep the private key in the signing account’s Keychain. Developer ID and notarization are separate from Sparkle signing.

The DMG packager loads the public US project settings from `Resources/release-usage.env`. Counts default to off until a user opts in. Set both `STILL_USAGE_TOKEN` and `STILL_USAGE_REGION` to empty strings to package a DMG without analytics. Plain source builds omit analytics unless both values are supplied.
