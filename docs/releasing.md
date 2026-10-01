# Releases

## Merge to release

**Release Me** runs on every push to `main`, including PR merges. Release Please collects conventional commits into a version and changelog PR. Ordinary merges create or update that PR; merging the release PR automatically:

1. Stages the GitHub release as a **draft** with its generated notes and exact source SHA.
2. Waits for the successful `main` CI run at that exact commit and checks all required source jobs.
3. Builds the app, signs it with Developer ID, creates the DMG, notarizes and staples it.
4. Creates the version tag at the verified source if it does not already exist, uploads the DMG, `SHA256SUMS.txt`, and signed `appcast.xml`, then downloads and verifies all three.
5. Publishes the release only after those checks pass.

No separate packaging action is required. A missing signing secret, failed CI/build/notarization, source mismatch, failed upload, or failed download verification leaves the release unpublished. The installer is built from the release PR's source, never a previously generated local DMG. Hosted build numbers are fixed to that source's Git commit count, which increases as commits land on `main`.

Tags use `vMAJOR.MINOR.PATCH`. `fix:` changes produce a patch and `feat:` changes produce a minor release. Docs and chores alone do not normally produce a release PR. Release Please updates `version.txt`, `CHANGELOG.md`, and `.release-please-manifest.json` in its PR; the initial baseline is the existing `v1.0.0` release.

Enable **Settings → Actions → General → Workflow permissions → Allow GitHub Actions to create and approve pull requests**. The workflow creates PRs but does not approve or merge them. Since PRs created with `GITHUB_TOKEN` do not trigger normal PR workflows, Release Me explicitly dispatches CI on the generated branch.

## Retry a failed release

The reusable **Build DMG and publish release** workflow also has a manual recovery entry point. Run it from `main` with the pending draft tag after fixing the failure. It resolves the draft's immutable source SHA and repeats the same build, verification, and publication path. Rerunning only Release Me's metadata job may not re-emit a draft already created, so use this recovery entry point for an existing draft.

Published releases are rejected and existing tags are never moved. Uploads do not overwrite existing assets. A partial upload can leave assets on the draft; inspect and remove only those failed-attempt assets deliberately before retrying. **Release verification** remains available to recheck an existing published installer without changing it.

Hosted CI runs macOS 26 with Xcode 27, so it can compile this macOS 27 app but cannot launch it. Native launch and real model generation remain separate validation; automatic publication does not claim they ran.

## One-time signing setup

In **Settings → Environments → release → Environment secrets**, configure:

| Secret | Value |
|---|---|
| `CERTIFICATE_P12_BASE64` | Base64-encoded, password-protected Developer ID Application certificate and private-key export for team `3Z3955EFRE`. |
| `SPARKLE_PRIVATE_KEY` | Exported Sparkle EdDSA private key matching the public key in AppInfo.plist. |
| `CERTIFICATE_PASSWORD` | Password for that P12 export. |
| `NOTARY_KEY_P8` | Complete App Store Connect API private key text, including its header and footer. |
| `NOTARY_KEY_ID` | Identifier of that API key. |
| `NOTARY_ISSUER_ID` | Issuer identifier for that API key. |

The existing `release` environment currently needs these six secrets before hosted packaging can run. The workflow reports missing secret names before contacting Apple. Credential values must never appear in source, issue comments, release notes, or command output. Adding local signing keys to GitHub is a separate setup action; adding this workflow does not transfer them.

Restrict the environment to the default branch and configure required reviewers if you want an additional approval before credentials become available. The workflow runs from the default branch and uses protected packaging scripts against the immutable release source SHA. Existing tags must resolve to that same commit. It uses the same hosted `xcode-27` runner as CI. Signing credentials are imported into a disposable keychain, and temporary key material is removed on exit.

## Package locally

Local packaging remains available from a clean checkout of a release tag. Set `RELEASE_TAG`, a `BUILD_NUMBER` equal to the tagged source’s Git commit count, `APPLE_TEAM_ID`, and the Apple signing variables above, then run `bash script/release.sh`. It produces the signed, notarized DMG, `SHA256SUMS.txt`, and signed `appcast.xml` in `dist/release` without publishing anything.

The verifier checks source CI, checksum, Developer ID team, signatures, stapled ticket, Gatekeeper, signed source SHA, version, architecture, and the Applications shortcut. Private downloads require repository access.

## Sparkle updates

The app uses Sparkle 2.9.6, offers **Check for Updates…** in the app menu,
and enables scheduled checks, automatic background downloads, and installation
by default. Sparkle handles installation through its standard update flow;
existing saved update preferences remain respected. End-to-end automatic installation and
relaunch will be tested after release. The feed is
`https://github.com/coryparrry/Foundation-Eval-Labs/releases/latest/download/appcast.xml`.
Each stable release must include its generated `appcast.xml` and be marked as the
latest release. Drafts and prereleases do not advance this feed. Publish the feed
and installer together; the feed points to that release's immutable download URL.

The EdDSA private key is stored locally in the macOS login Keychain under the
Sparkle account `foundation-evals`. Only the public key belongs in source control.
Back up the private key securely using Sparkle's `generate_keys --account
foundation-evals -x <secure-backup-path>` before changing machines; never commit
the export. Hosted packaging reads `SPARKLE_PRIVATE_KEY` from the release environment into a temporary protected file removed on exit. Configuring that secret is a separate credential-transfer action. Local packaging defaults to the Keychain account when the variable is absent. Packaging uses the pinned package's `generate_appcast` tool and this
account to sign the final stapled DMG. Do not replace the key for routine releases.

Before the first updater release, install an older Sparkle-enabled signed build
in Applications and exercise **Check for Updates…**, download, installation, and
relaunch against a newer signed build. Confirm version advancement and retained
suites/history. A build that predates Sparkle requires one manual download; it
cannot acquire the updater remotely. Build success alone does not prove this
end-to-end update path.
