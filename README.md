# GitLab Mobile

> **Development home:** https://gitlab.com/aa22396584/gitlab-mobile  
> Please open issues and merge requests there.

A mobile-first Flutter client for Android and iOS. Independent third-party software, not an official GitLab application. The interface is Traditional Chinese and supports light/dark appearance and large text.

## 2026-10-02 — mobile parity and performance follow-up

The current development branch adds issue boards and card/list management,
revision comparison, server-backed MR draft review, selected-ref repository
graphs, actual pipeline dependency graphs, package/container/Terraform registries,
explicitly enumerated single-file Snippets, and typed Task/Incident workflows
with separate incident escalation state. Issue/MR filters use server
ordering. Phone board columns, vertical graphs and lazy lists retain native
navigation. The [full-function ledger](docs/MOBILE_WEB_PARITY_LEDGER.md) records
all 30 observed Web project entries and keeps every remaining workflow open;
these additions do not establish complete GitLab parity.

Loading and scroll work adds a bounded, account-client in-memory read cache for project resolution and immutable-SHA text, concurrent request sharing, memoized list derivation and a page-owned syntax-span LRU. Server cache directives, explicit refresh, writes, account/client changes and authorization failures invalidate or disable reuse. See the [current parity and performance report](docs/MOBILE_PARITY_PERFORMANCE.md) for the complete Web navigation matrix, safety boundaries, measured results and remaining NOT_RUN lanes.

## v0.5 — mobile UX overhaul and GitLab parity

Still a development preview. Evidence is in the [v0.5 ledger](docs/V0_5_VERIFICATION.md); anything it does not list is **NOT_RUN**.

- Chrome gives way to content: page headers collapse while scrolling and return on any scroll up, the bottom navigation hides on scroll, and tapping the active destination scrolls its list to the top. The projects tab has a floating search bar; filters, sorting and recent projects scroll away with the list.
- On phones an issue or merge request opened inside a project owns the screen: the project header and tabs step aside instead of stacking a second app bar and tab bar above the detail.
- Dense lists: grouped rows for projects, files, pipelines, jobs and activity; issue and MR rows show GitLab label colours (scoped `scope::value` labels as two segments), assignees, comment and task counts, due dates and conflicts. System notes in discussions are one-line timeline entries. Code rows are text height with a 48 dp line-number column.
- New GitLab features: search across the instance (projects, issues, MRs, milestones, users) and inside a project (code, commits, comments, wiki, plus the same kinds), run when submitted; groups with subgroups, projects, issues and MRs; project and personal activity feeds; emoji reactions; related merge requests and linked issues; due date, time tracking, weight and notification subscription; MR commits, MR pipelines and a draft/ready toggle; file history, blame and find-file; project overview with stars, forks, languages, licence, clone URLs, the viewer's star state and fork; members, wiki, environments, deployments and pipeline schedules (run now); jobs grouped by stage, showing the latest attempt of retried jobs.
- Inbox: a swiped todo is marked done after a 4-second 復原 window (tab paging is off so a sideways swipe always means the row); 全部完成 asks first; assigned, review-requested and created-by-me lists switch between issues and MRs.
- Pasting a GitLab issue, MR, pipeline, job, commit or SHA-pinned file link into 以連結或路徑開啟 opens that resource. A link to a project the account cannot see opens the ambiguous-404 notice (account, instance, target, retry, switch account).

## v0.3 — collaboration preview

This revision continues the v0.2 API-backed collaboration screens. It is a **development preview**, not a claim that every GitLab feature, server edition, permission configuration, or device has passed end-to-end testing. !3, !7, !6, !8, !5 and !4 are merged. `main` is `9183f19`. A behaviour was exercised only on the build named in the [v0.3 ledger](docs/V0_3_VERIFICATION.md).

- PAT sign-in, account identity verification, multiple account isolation, removal of a saved account, GitLab.com and HTTPS self-managed instances. OAuth PKCE is wired and stays inert until a real Application ID is registered for that instance.
- Device appearance (light, dark, or system) stored on the device and restored after a force-kill (!3). The same key stores the Material You dynamic-colour flag (!6).
- Project membership/starred/accessibility search, private project lookup by numeric ID or full namespace, project create/edit/delete, star/unstar, and a pending-deletion badge (!5).
- Branch-aware fixed-SHA repository browsing, Markdown/raw text, file create/read/edit/delete with `last_commit_id`, branch/tag create/read/delete and commit history.
- Issue and merge-request create/read/edit/delete, close/reopen, self-assignment, labels and personal todos. Label, assignee, reviewer and branch pickers (!7).
- Notes and threaded discussions, replies, own-note edit/delete, discussion resolve/reopen, collapsed resolved threads with an unresolved filter and summary (!3), bounded pinned-version diffs, validated single-line review positions, and existing discussions shown on the diff (!4).
- SHA-bound approval/merge requests. The merge dialog offers squash and remove-source-branch, and the MR overview has a review card (!3). GitLab remains authoritative for permissions, review policy, protected branches and mergeability.
- Last-account auto-resume on launch (!4).
- Project pipelines, run/retry/cancel/delete, job status/logs/retry/manual play, bounded foreground log polling, and collapsible log sections (!5). The `db12b41` build opens the artifact page in the system browser. On `main`, job archives download in-app: authenticated first hop, exactly one https redirect, no credential headers on that hop.
- Attachment upload (`POST /projects/:id/uploads`, multipart, 25 MiB) and a Markdown toolbar with 編輯／預覽 (!7).
- Material You dynamic colour, predictive back, edge-to-edge layout, and launcher shortcuts (`inbox`, `search`, `recent:<projectId>:<digest>`) (!6).
- Release, project-label and milestone CRUD. Commits are immutable; branches and tags are not presented as having a fictitious update API.
- Account-scoped encrypted drafts, retained write errors, no automatic retry of uncertain writes, typed confirmation for destructive resource operations.

**Historical v0.3 boundary (at `9183f19`):** OAuth login stayed inert, and push delivery, iOS, a cross-project CI overview and a two-pane wide layout were not in that revision. The current source now contains cross-project CI and retained-state two-pane layouts; see the v0.5 ledger and current parity report for their separate evidence limits. Local Git clone/rebase/terminal and complete enterprise policy management remain outside the tree. App Store / Play signing, an independent human review, a physical-phone run of !4–!8, and a completed live CI job-control suite were **NOT_RUN** for v0.3. Device evidence was one physical Android phone and one Android emulator. The live smoke was not re-run after those merges. Anything this historical section does not tie to the v0.3 ledger stays **NOT_RUN** for that revision.

## Verification

See [current mobile parity and performance](docs/MOBILE_PARITY_PERFORMANCE.md), [v0.5 verification](docs/V0_5_VERIFICATION.md), [v0.3 verification](docs/V0_3_VERIFICATION.md), [v0.2 verification](docs/V0_2_VERIFICATION.md) and [mobile UX changes](docs/UI_REDESIGN.md). CI executes the actual Dart/Flutter code. Synthetic transport tests, live server checks, emulator runs and physical-device runs stay distinct. On `9183f19`, pipeline `2869335026` reported `509` tests in its JUnit report. That is the observed count for that pipeline.

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

A production-client run on 2026-09-21/22 is recorded in the [v0.3 ledger](docs/V0_3_VERIFICATION.md): **33 PASS / 1 FAIL** against an isolated private GitLab.com project. The failure is shared-runner quota (`ci_quota_exceeded`), not a client defect, and the check is still FAIL. `smoke-output/report.json` is not committed. Pipeline retry / cancel / delete did not run in that execution. The smoke was not re-run after the merges.

## Historical specifications

`docs/plan/` preserves the original 105-operation design and acceptance plan. It is a **target specification**, not proof that every operation has been implemented or verified. Earlier G0/R1 documents and package manifests are historical handoffs; the current Git history, CI results, and the v0.2 and v0.3 verification ledgers supersede their status statements.

## License

GNU Affero General Public License v3.0 (AGPL-3.0). Copyright (C) 2026 ImL1s. See [LICENSE](LICENSE).
