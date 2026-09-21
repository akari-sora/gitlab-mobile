# GitLab Mobile

> **Development home:** https://gitlab.com/aa22396584/gitlab-mobile  
> Please open issues and merge requests there.

A mobile-first Flutter client for Android and iOS. Independent third-party software, not an official GitLab application. The interface is Traditional Chinese and supports light/dark appearance and large text.

## v0.3 — collaboration preview

This revision continues the v0.2 API-backed collaboration screens. It is a **development preview**, not a claim that every GitLab feature, server edition, permission configuration, or device has passed end-to-end testing. Merge requests !3–!7 were open when the [v0.3 ledger](docs/V0_3_VERIFICATION.md) was written. A behaviour named with an MR is on that branch.

- PAT sign-in, account identity verification, multiple account isolation, removal of a saved account, GitLab.com and HTTPS self-managed instances. OAuth PKCE is wired and stays inert until a real Application ID is registered for that instance.
- Device appearance (light, dark, or system) stored on the device and restored after a force-kill (!3).
- Project membership/starred/accessibility search, private project lookup by numeric ID or full namespace, project create/edit/delete, star/unstar, and a pending-deletion badge (!5).
- Branch-aware fixed-SHA repository browsing, Markdown/raw text, file create/read/edit/delete with `last_commit_id`, branch/tag create/read/delete and commit history.
- Issue and merge-request create/read/edit/delete, close/reopen, self-assignment, labels and personal todos. Label, assignee, reviewer and branch pickers (!7).
- Notes and threaded discussions, replies, own-note edit/delete, discussion resolve/reopen, collapsed resolved threads with an unresolved filter and summary (!3), bounded pinned-version diffs, validated single-line review positions, and existing discussions shown on the diff (!4).
- SHA-bound approval/merge requests. The merge dialog offers squash and remove-source-branch, and the MR overview has a review card (!3). GitLab remains authoritative for permissions, review policy, protected branches and mergeability.
- Last-account auto-resume on launch (!4).
- Project pipelines, run/retry/cancel/delete, job status/logs/retry/manual play, bounded foreground log polling, and collapsible log sections (!5). The `db12b41` build opens the artifact page in the system browser. !5 downloads the job archive in-app: one https redirect, no credential headers on that hop.
- Attachment upload and a Markdown toolbar (!7).
- Material You dynamic colour, predictive back, edge-to-edge layout, and launcher shortcuts from the last opened project (!6).
- Release, project-label and milestone CRUD. Commits are immutable; branches and tags are not presented as having a fictitious update API.
- Account-scoped encrypted drafts, retained write errors, no automatic retry of uncertain writes, typed confirmation for destructive resource operations.

**Not yet implemented:** OAuth login still needs a registered Application ID per instance. Push delivery, local Git clone/rebase/terminal, and complete enterprise policy management are not in the tree. iOS is deferred by the maintainer. App Store / Play signing, an independent human reviewer, and a completed live CI job-control suite are **NOT_RUN**. Device evidence is one physical Android phone and one Android emulator; the matrix is still open. Anything this README does not tie to the v0.3 ledger stays **NOT_RUN**.

## Verification

See [v0.3 verification](docs/V0_3_VERIFICATION.md), [v0.2 verification](docs/V0_2_VERIFICATION.md) and [mobile UX changes](docs/UI_REDESIGN.md). CI executes the actual Dart/Flutter code. Synthetic transport tests, live server checks, emulator runs and physical-device runs stay distinct. Flutter test totals are read from the CI job report.

A real GitLab `Link` header expanded omitted `false` defaults and caused the original project-list failure. The parser now validates immutable scope, preserves the caller's query, and extracts only a safe pagination cursor. Valid first-page data is no longer rejected because GitLab expanded defaults.

## Build and CI

Pinned Flutter **3.47.2** / Dart **3.13.2**; committed `pubspec.lock`. Normal pipelines enforce the lock, run analysis and unit/widget tests, capture actual Flutter-rendered synthetic-data screenshots, generate/check Android/iOS templates, then build an Android debug APK. Only successful `main` pipelines publish commit-addressed preview packages using `CI_JOB_TOKEN`.

```sh
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub
python3 tool/bootstrap.py
flutter build apk --debug
```

Screenshots: `flutter_checks` job artifacts → `ci-output/screenshots/`. They are real Flutter host-rendered screens with synthetic data, not an Android/iOS device run or a generated design mock-up. Android APKs: `android_debug` artifacts; main previews: project Package Registry. Debug signing may differ across clean builds; these are not store-signed releases.

## Live CRUD smoke

`tool/live_smoke.dart` uses the production Dart API client and a unique, isolated **private** project. It validates the expected account, performs read-after-write checks and cleans up only its exact synthetic project. Credentials are read from a runtime file; never commit a PAT or use a Dart compile-time define for one.

The `live_crud_smoke` job runs only in an explicit API-triggered pipeline with `LIVE_SMOKE=1`. The credential must be supplied through a secure mechanism approved for the execution environment. Do not bypass that boundary. The normal APK does not include a test PAT.

A production-client run on 2026-09-21/22 is recorded in the [v0.3 ledger](docs/V0_3_VERIFICATION.md): **33 PASS / 1 FAIL** against an isolated private GitLab.com project. The failure is shared-runner quota (`ci_quota_exceeded`), not a client defect, and the check is still FAIL. `smoke-output/report.json` is not committed. Pipeline retry / cancel / delete did not run in that execution.

## Historical specifications

`docs/plan/` preserves the original 105-operation design and acceptance plan. It is a **target specification**, not proof that every operation has been implemented or verified. Earlier G0/R1 documents and package manifests are historical handoffs; the current Git history, CI results, and the v0.2 and v0.3 verification ledgers supersede their status statements.

## License

MIT. See [LICENSE](LICENSE).
