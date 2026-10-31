# Mergeline

<p align="center">
  <img src="docs/media/feature.jpg" alt="Mergeline — a third-party mobile client for GitLab®" width="640">
</p>

**GitLab®, in your pocket.** Mergeline is a mobile-first client for GitLab.com and self-managed GitLab: issues, merge-request review and merge, CI/CD pipelines and logs, files and an inbox — plus a **bring-your-own-key AI assistant** that explains code and proposes changes, each one confirmed by you.

- ▶️ **Demo video:** [youtube.com/watch?v=oXaaAxL1h_E](https://www.youtube.com/watch?v=oXaaAxL1h_E)
- 📦 **Android (GitLab channel, free):** [latest release](https://gitlab.com/aa22396584/gitlab-mobile/-/releases) — installed builds update themselves under 我的 › 應用程式更新
- 🛒 **Google Play (US$3.99):** [play.google.com/store/apps/details?id=app.mergeline](https://play.google.com/store/apps/details?id=app.mergeline)
- 🧪 **Try without an account:** tap **試用 Demo** on the sign-in screen

> Canonical repository, issues and merge requests: https://gitlab.com/aa22396584/gitlab-mobile.
> Independent third-party software, not affiliated with or endorsed by GitLab Inc. GITLAB is a trademark of GitLab Inc.

<p align="center">
  <img src="docs/media/demo-ai.gif" alt="The AI assistant explains a file, proposes a comment, and writes it after approval (Demo mode)" width="640">
</p>

## Screenshots

| Your GitLab, at hand | Review code | Approve and merge | CI/CD at a glance |
|---|---|---|---|
| <img src="docs/media/screenshot-1-home.jpg" width="160" alt="Home"> | <img src="docs/media/screenshot-2-review.jpg" width="160" alt="Merge request diff with a discussion"> | <img src="docs/media/screenshot-3-merge.jpg" width="160" alt="Merge request summary with approve and merge"> | <img src="docs/media/screenshot-4-ci.jpg" width="160" alt="Pipeline jobs"> |

| Whole project | AI proposes, you approve | Written, then read back |
|---|---|---|
| <img src="docs/media/screenshot-5-project.jpg" width="160" alt="Project overview"> | <img src="docs/media/screenshot-6-ai-confirm.jpg" width="160" alt="AI confirmation card"> | <img src="docs/media/screenshot-7-ai-done.jpg" width="160" alt="The AI write, confirmed by a read-back"> |

All screenshots and the video show **Demo mode** with sample data.

## Features

- **Work from your phone:** projects, files and Markdown (images, tap-to-load audio and video), issues and work items, merge requests with diffs, inline discussions, approvals and merge, pipelines with jobs and live logs, releases, labels, milestones, snippets, wiki and more.
- **Inbox:** todos, review requests, mentions and assignments, with swipe-to-done.
- **AI assistant (bring your own key):** OpenAI-compatible Chat Completions, OpenAI Responses and Anthropic Messages. The assistant reads the page you are on and, when needed, more of the same project; it can propose any write the app itself can do.
  - Every write shows a **confirmation card** first; high-risk writes need you to type the name; each write is read back.
  - Secrets are masked before anything leaves the device; sensitive files are withheld.
  - Report an AI answer from inside the app (回報).
- **Accounts and privacy:** GitLab.com and HTTPS self-managed instances, several accounts, PAT sign-in, an app lock, encrypted drafts and optional encrypted AI history. No developer server, no analytics, no ads — see the [privacy policy](docs/PRIVACY.md).
- **Offline reading:** an encrypted read cache and offline repository copies.
- **24 languages**, light/dark appearance, dynamic colour and large text.

## Supported GitLab versions

The app needs **GitLab 18.11** or later (GitLab.com or HTTPS self-managed instances). Older instances stay readable where possible, but some screens report `unsupported` instead of loading. Work-item comment writes, including AI-assisted writes, need GitLab 18.9+, which the minimum covers. One exception: the work-item development row's closing-merge-requests count needs GitLab 19.4 and shows as unavailable below that.

## Documentation

- [Changelog](CHANGELOG.md) — what changed in each release.
- [Documentation index](docs/README.md) — plans and status, privacy, store listing, CI, signing, verification ledgers and audits.
- [Plan and status](docs/PLAN_STATUS.md) — what is being built, in what order, and where each piece stands.

## Verification

See [Plan and status](docs/PLAN_STATUS.md), [v0.6 AI verification](docs/V0_6_AI_VERIFICATION.md), [current mobile parity and performance](docs/MOBILE_PARITY_PERFORMANCE.md), [v0.5 verification](docs/V0_5_VERIFICATION.md), [v0.3 verification](docs/V0_3_VERIFICATION.md), [v0.2 verification](docs/V0_2_VERIFICATION.md) and [mobile UX changes](docs/UI_REDESIGN.md). CI executes the actual Dart/Flutter code. Synthetic transport tests, live server checks, emulator runs and physical-device runs stay distinct. On `aa47e464` (v0.6.0), pipeline `3006901467` reported `16,424` passed tests in the AI-off lane and `17,583` in the AI-on lane (one skipped each) in its JUnit reports; current counts are read from each pipeline's report.

A real GitLab `Link` header expanded omitted `false` defaults and caused the original project-list failure. The parser now validates immutable scope, preserves the caller's query, and extracts only a safe pagination cursor. Valid first-page data is no longer rejected because GitLab expanded defaults.

## Build and CI

Pinned Flutter **3.47.2** / Dart **3.13.2**; committed `pubspec.lock`. Normal pipelines enforce the lock, run analysis and unit/widget tests in both the default and AI-on lanes (`flutter_checks` and `flutter_ai_checks`), capture actual Flutter-rendered synthetic-data screenshots, generate/check Android/iOS templates, then build the `gitlab`-flavor Android APK (release on protected refs `main` and `v*` tags, debug elsewhere; docs-only merge requests skip the Flutter, native and Android jobs). Only successful `main` pipelines publish commit-addressed preview packages using `CI_JOB_TOKEN`.

```sh
fvm flutter pub get --enforce-lockfile
fvm flutter analyze --no-pub
fvm flutter test --no-pub
python3 tool/bootstrap.py --flutter .fvm/flutter_sdk/bin/flutter
python3 tool/android_signing.py configure android/app/build.gradle.kts
fvm flutter build apk --debug --flavor gitlab
```

Launcher icon: `assets/icon/*.png` are rendered from the vector design in `tool/render_icon.py` (`python3 tool/render_icon.py --chromium <chromium or headless_shell>`); `tool/bootstrap.py` and `ci/build_android.sh` turn them into platform icon sets with `flutter_launcher_icons`. Edit the script, not the PNGs.

Screenshots: `flutter_checks` job artifacts → `ci-output/screenshots/`. They are real Flutter host-rendered screens with synthetic data, not an Android/iOS device run or a generated design mock-up. Android APKs: `android_debug` artifacts; main previews: project Package Registry. Local debug, profile and release APKs use the stable development signer described in [Android local signing](docs/ANDROID_SIGNING.md). Published CI previews from `main` and release tags are **release** builds of the `gitlab` flavor, signed by a separate stable CI identity held in a protected CI variable (see [CI](docs/CI.md#android-signing-lanes)); merge-request builds are debug builds signed with a discarded ephemeral key. Neither path is a store-signed release.

## Live CRUD smoke

`tool/live_smoke.dart` uses the production Dart API client and a unique, isolated **private** project. It validates the expected account, performs read-after-write checks and cleans up only its exact synthetic project. Credentials are read from a runtime file; never commit a PAT or use a Dart compile-time define for one.

The `live_crud_smoke` job runs only in an explicit API-triggered pipeline with `LIVE_SMOKE=1`. The credential must be supplied through a secure mechanism approved for the execution environment. Do not bypass that boundary. The normal APK does not include a test PAT.

A production-client run on 2026-09-21/22 is recorded in the [v0.3 ledger](docs/V0_3_VERIFICATION.md): **33 PASS / 1 FAIL** against an isolated private GitLab.com project. The failure is shared-runner quota (`ci_quota_exceeded`), not a client defect, and the check is still FAIL. `smoke-output/report.json` is not committed. Pipeline retry / cancel / delete did not run in that execution. The smoke was not re-run after the merges. For AI writes, the MR7 sandbox runner (`tool/run_mr7_sandbox.py`, [docs/MR7_SANDBOX.md](docs/MR7_SANDBOX.md)) and the v0.6.0 `gpt-4o-mini` emulator walkthrough on a run-owned private sandbox project are recorded in [Plan and status](docs/PLAN_STATUS.md).

## Historical specifications

The original 105-operation design and acceptance plan was a separate historical handoff artifact (not in this checkout) and is a **target specification**, not proof that every operation has been implemented or verified. Current working design plans live in [`docs/plans/`](docs/plans/) and are tracked in [Plan and status](docs/PLAN_STATUS.md). Earlier G0/R1 documents and package manifests are historical handoffs; [Plan and status](docs/PLAN_STATUS.md), the current Git history, CI results, and the verification ledgers listed in [docs/README.md](docs/README.md) supersede their status statements.

## License

GNU Affero General Public License v3.0 (AGPL-3.0). Copyright (C) 2026 ImL1s. See [LICENSE](LICENSE).
