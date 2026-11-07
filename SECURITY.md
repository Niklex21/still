# Security

Still is a local screenshot tool. Captures can contain passwords, personal information, and confidential work. Please do not attach real screenshots or your library to a public issue.

## Reporting a vulnerability

Use [GitHub's private vulnerability reporting](https://github.com/Niklex21/still/security/advisories/new) for a sensitive report. Include the affected version, reproduction steps using synthetic data, expected impact, and relevant code. If the private form is unavailable, open an issue asking for a private reporting channel without disclosing the vulnerability.

The latest preview is the supported version. This is a small community project: there is no guaranteed response time, independent audit, or security certification.

## What to verify before installing

- Download only from [this repository's releases](https://github.com/Niklex21/still/releases), or inspect the source and build it yourself.
- Preview DMGs are **not notarized** and use an ad-hoc signature. An integrity check is not Apple approval or verified publisher identity. See [installation and release details](docs/releases.md).
- A published SHA-256 checksum detects a damaged or mismatched download. It does not protect against a compromised repository or release account.
- Grant screen recording only if you trust the app. Still does not need Full Disk Access. Accessibility is requested only for programmatic scrolling; manual scrolling is available.

## Maintenance

CI builds native Swift code, runs unit and synthetic native workflow checks, and tests/audits the optional Raycast extension. CodeQL scans JavaScript/TypeScript in Raycast; **it does not audit the native Swift app**. Actions are pinned to immutable revisions, workflow tokens have scoped permissions, and Dependabot proposes dependency updates. None of these replaces review or real-device testing.

See [privacy and data handling](docs/privacy.md), including original images retained after redaction.
