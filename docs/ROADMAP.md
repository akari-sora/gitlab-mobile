# Product roadmap and acceptance boundaries

This repository imports the G0 R1 application slice, its Flutter regression tests and the native bootstrap from the September 19, 2026 handoff. CI-specific fixes and tests are subsequent commits. The full earlier 105-operation research/specification ZIP is a separate handoff artifact; it has not all been imported into this repository. Do not interpret these implementation notes as a replacement for that catalogue or a claim that all 105 APIs work.

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

Status (2026-09-22): OAuth login, push, iOS, store signing, TalkBack, a cross-project CI overview, a two-pane layout, and a phone run of !4–!8 remain NOT_RUN. See the [v0.3 ledger](V0_3_VERIFICATION.md). `main` is `9183f19`; pipeline `2869335026` reported `509` tests.
