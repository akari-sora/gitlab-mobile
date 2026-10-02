# Product roadmap and acceptance boundaries

This repository imports the G0 R1 application slice, its Flutter regression tests and the native bootstrap from the September 19, 2026 handoff. CI-specific fixes and tests are subsequent commits. The full earlier 105-operation research/specification ZIP is a separate handoff artifact; it has not all been imported into this repository. Do not interpret these implementation notes as a replacement for that catalogue or a claim that all 105 APIs work.

## Current follow-up — mobile parity and performance (2026-10-02)

The branch based on `0e1298e` adds boards/card moves/list management, server-backed
MR draft review, revision compare, native issue/MR filters, repository and
pipeline dependency graphs, registries, single-file Snippets and typed Task/Incident workflows. Account-client
read caching, request sharing, lazy list derivation and syntax-span LRU reduce
repeated work. See [the parity/performance report](MOBILE_PARITY_PERFORMANCE.md)
and [the full-function ledger](MOBILE_WEB_PARITY_LEDGER.md).

Core board and draft workflows now have source/tests. Draft bulk publication still
has GitLab's concurrent-change interval after its final GET. Typed GraphQL work
items, paid board scope/list creation, all-branch graph, multi-file Snippets,
registry downloads/publishing, complete incident operations and live lifecycle proof, Service Desk, analytics, OAuth live
login and push remain open under the all-function goal. Exact-head CI, Android
readback, live private/CRUD and iOS acceptance remain separate evidence lanes.

## G0 — Identity and private repository reader (implemented slice, acceptance incomplete)

Native mobile UX: sign in, explicitly verify `/user`, separate member/starred/accessible project scopes, resolve private project URLs, browse one fixed commit SHA and read bounded raw text. Distinguish authentication failure, authorization failure, ambiguous 404, rate limits, network failures, unsupported content and oversized files. Preserve page-one content after page-two failure; prevent stale requests changing a new account or folder.

Implemented REST operations:

| Operation | Endpoint | Main evidence |
|---|---|---|
| Identity | `GET /user` | `test/gitlab_api_test.dart`, `test/session_test.dart` |
| Project lists/search | `GET /projects` | `test/gitlab_api_test.dart` |
| Project resolution | `GET /projects/:id` | `test/identity_test.dart`, `test/gitlab_api_test.dart` |
| Default branch SHA | `GET /projects/:id/repository/branches/:branch` | `test/gitlab_api_test.dart` |
| Tree | `GET /projects/:id/repository/tree` | `test/repository_controller_test.dart` |
| File metadata | `HEAD /projects/:id/repository/files/:path` | `test/gitlab_api_test.dart` |
| Raw content | `GET /projects/:id/repository/files/:path/raw` | `test/gitlab_api_test.dart` |

Real GitLab private-resource integration and Android/iOS device acceptance are still required. Synthetic fixtures are not integration evidence. CI-generated debug APKs are not proof of successful device operation.

Status (2026-09-22): private-project evidence is in [v0.3 verification](V0_3_VERIFICATION.md) — one live smoke of the production client (not re-run after the merges), plus one physical phone on `db12b41` and the !3 build. !4–!8 were walked on one Pixel 9 emulator. The device matrix is still open. This is not G0 acceptance.

## G1 — Complete read-only workflows

Branches, tags, commits, releases, MR/Issue reading, CI/log viewing, search and adaptive navigation. Add real empty/loading/error/partial/offline states; bounded large content; account-separated local persistence only after encryption/migration validation. Preserve navigation and scrolling between roots and on foldable resize.

Status (2026-09-22): the [v0.3 ledger](V0_3_VERIFICATION.md) records a phone walk of search, a private project's files and Markdown, and a public project's issue, MR and CI lists. Inbox and the project More tab were not walked on that phone. Emulator polish `c90ca15` showed inbox todo cards, and a cold start through the inbox shortcut landed on 收件匣. The More tab walk is NOT_RUN.

## G2 — Comments and issues

Resource-scoped local drafts, create/edit/reply, attachment handling and conflict recovery. Keep drafts after failures and process termination. Never blindly retry a write after an ambiguous network timeout.

Status (2026-09-22): the [v0.3 ledger](V0_3_VERIFICATION.md) records phone evidence for issue create, a comment, secure-draft restore after force-kill, and a typed delete. !7 is merged (`3891577`). Emulator evidence is !7 screenshots of the pickers and Markdown toolbar, and on `c90ca15` the label picker (search, empty state), the 8-action toolbar and 編輯／預覽. Live attachment upload and a phone run of those screens are NOT_RUN.

## G3 — MR review

Mobile unified diff, correctly mapped old/new line anchors, discussion threads, SHA-bound approvals/merges and stale-version checks. Do not manufacture omitted server diff content or interpret accepted auto-merge as completed merge.

Status (2026-09-22): the [v0.3 ledger](V0_3_VERIFICATION.md) records phone evidence on !3 for the overview review card, merge-option switches (dialog cancelled), and collapsed resolved discussions. !4 is merged (head `92f8c9f`, merge `9183f19`). Emulator `fa529a2` showed a positioned discussion under `lib/core/workspace_api.dart` line 41. A phone run of inline discussions is NOT_RUN.

## G4 — CI operations

Run/retry/cancel/manual play, correct job-attempt identity, foreground log updates with a bounded budget, artifacts without token-bearing third-party redirects. These refer to the App's GitLab controls, not this repository's own CI setup.

Status (2026-09-22): the [v0.3 ledger](V0_3_VERIFICATION.md) records a phone walk of pipeline, jobs and a 10-second log refresh on `db12b41` (the artifact menu opened the browser). !5 is merged (`fd14809`). Emulator `9789033` / `e9e1965`: 83.4 MB `artifacts.zip` finished, with 開啟／分享, 在 GitLab 開啟, and collapsible log sections with durations. The live smoke was not re-run after the merges; the job-control check stays FAIL (`ci_quota_exceeded`). Full-suite live CI job control is NOT_RUN.

## G5 — Release quality

Actual Android/iOS device matrix, TalkBack/VoiceOver, large text and narrow-screen layout, network and account-switch races, secure-storage backup/restore, performance measurements, stable signing and distribution. OAuth PKCE, push and platform links require explicit capability checks; do not present a nonfunctional switch as supported.

For each gate record commit SHA, pipeline/job URLs, fixtures/environment, executed cases, failures and NOT_RUN items. No global PASS based solely on unit tests or template generation.

Historical status (2026-09-22, `9183f19`): OAuth login, push, iOS, store signing, TalkBack, a cross-project CI overview, a two-pane layout, and a phone run of !4–!8 remained NOT_RUN. Cross-project CI and retained-state two-pane layouts landed later; consult the v0.5 ledger and current parity report for their evidence boundaries. See the [v0.3 ledger](V0_3_VERIFICATION.md). Pipeline `2869335026` reported `509` tests for that revision.

## R4 — Follow-up specifications and Backlog (D1~D5 & Long-term)

The follow-up engineering slices (D1~D5) and long-term backlog bridge the gaps identified in `docs/GITLAB_WEB_VS_MOBILE_GAP_AUDIT.md`. They are preserved with explicit technical dependency paths and acceptance criteria.

### D1: Pipeline JUnit Test Report (`GET .../pipelines/:id/test_report`)
- **Specification**: In `PipelinePage`, display a top test-result summary card (Total, Passed, Failed, Skipped). When failed tests > 0, highlight with red indicator; tap to open a dedicated test failure browser showing suite name, test name, duration, and error stacktrace.
- **Dependencies**: `lib/features/workspace/ci_page.dart`, `lib/core/gitlab_api.dart` (bounded by 4 MiB streaming budget; payloads exceeding 4 MiB fail safe with `tooLarge` and offer external browser fallback).
- **Acceptance Criteria**:
  - Accurate parsing of standard GitLab test report payload.
  - Zero crashes on empty or oversized test reports.
  - Regression unit tests covering report models, failure lists, and error states.

### D2: Commit Diff and Changed Files List (`GET .../commits/:sha/diff`)
- **Specification**: Extend commit details (`project_more_page.dart`) to fetch commit diffs and embed `ReviewDiffPage`, providing changed file list, addition/deletion stats, and unified diff viewing on mobile.
- **Dependencies**: `lib/core/unified_diff.dart`, `lib/features/workspace/diff_page.dart`.
- **Acceptance Criteria**:
  - Tapping a commit displays the list of touched files with additions/deletions badges.
  - Tapping a changed file displays line-by-line unified diff.
  - Binary and oversized diffs (> 2 MiB) gracefully display informational placeholders.

### D3: Auto-Merge When Pipeline Succeeds (MWPS / Auto-merge)
- **Specification**: Extend `mergeRequest` in `workspace_api.dart` with `merge_when_pipeline_succeeds: true`. In `work_item_page.dart`, when `detailed_merge_status` is `ci_still_running`, present the action button as "Auto-merge when pipeline succeeds" rather than failing with 405/406.
- **Dependencies**: `lib/core/workspace_api.dart`, `lib/features/workspace/work_item_page.dart`.
- **Acceptance Criteria**:
  - Scheduling auto-merge on running pipeline succeeds without unexpected error dialogs.
  - Dynamic button state updates to indicate scheduled status or cancel option.
  - Unit tests covering MWPS API parameter dispatch and status transitions.

### D4: Terminal ANSI Color Rendering & Streaming Robustness
- **Specification**: Replace regex stripping in `lib/core/job_trace.dart:35` with a pure-Dart ANSI state machine, translating SGR escape sequences (red/green/yellow/cyan, bold, dim) into styled `TextSpan` elements.
- **Dependencies**: `lib/core/job_trace.dart`, `lib/features/workspace/ci_page.dart`, HTTP Range 206 chunking (must gracefully handle escape sequences split across chunk boundaries).
- **Acceptance Criteria**:
  - Accurate rendering of standard 8/16-color ANSI output for compilation errors and test outcomes.
  - Robust state-machine recovery across segmented chunks without emitting garbage glyphs.
  - Performance validation ensuring smooth scrolling over 20,000 log lines.

### D4.1 / CI-LOG-SEARCH: In-Job Terminal Log Search & Navigation (MR !24)
- **Specification**: In-job terminal log search with match highlighting, occurrences counter, and next/prev match scrolling.
- **Dependencies**: `lib/features/workspace/ci_page.dart`.
- **Acceptance Criteria**:
  - Incremental search over Virtualized ANSI spans with keyboard and tap navigation.
  - Correct jump-to-offset and match highlight styling without breaking log stream.

### D5 / REPO-SYNTAX: Code Reading Experience Suite
- **D5.1 Collapsible README.md Preview**:
  - Render collapsible `MarkdownView` card at the top of the repository file tree.
- **D5.2 Tag Ref Picker for Repository Tree**:
  - Add Tag selection sheet in `repository_page.dart`, integrating tags list from `project_more_page.dart`.
- **D5.3 Lightweight Syntax Highlighting**:
  - Pure-Dart token coloring for major languages (Dart, Python, JS, Go, JSON, YAML) in `repository_page.dart:666` preserving line virtualization.
- **D5.4 Line Number Interaction & Permalink Sharing**:
  - Interactive line number selection, highlighting, and copying URL anchors (`#L12-L20`).
- **Acceptance Criteria**:
  - README expands/collapses smoothly and remembers user preference.
  - Tag selection pins tree to the resolved tag commit SHA without branch drift.
  - Zero frame drops during fast scrolls on large code files (> 5,000 lines).

Status (2026-10-02): D1–D5 had already landed on `main` before v0.5. v0.5 adds group browsing (the read side of LT1: groups, subgroups, group projects, group issues and MRs), emoji reactions, scoped-label rendering, global and per-project search, activity feeds, file history, blame and find-file, related items, members, wiki, environments, deployments and pipeline schedules. Evidence and NOT_RUN items are in the [v0.5 ledger](V0_5_VERIFICATION.md). The current follow-up adds board management/card moves, core server drafts and actual pipeline needs graphs; GraphQL work items (LT2), paid board semantics and full downstream DAG workflows remain open.

### Long-Term Backlog (LT1 ~ LT5)
- **LT1: Groups & Subgroups Hierarchy (`GET /groups`)**: Flattened multi-level hierarchy browsing, subgroup navigation, and group-scoped project discovery.
- **LT2: GraphQL Polymorphic Work Items Pilot**: Targeted GraphQL queries for Task checkbox toggling and Epic linking alongside existing REST infrastructure.
- **LT3: Issue Boards Kanban View**: Horizontal swiping board columns for label/milestone workflows on tablets (>= 840 dp).
- **LT4: Batch Review & Draft Notes**: Integration with server-side draft notes API for staging comments and submitting unified reviews.
- **LT5: Suggested Changes Application**: Markdown rendering of ```suggestion blocks with one-tap commit application via GitLab suggestions API.
