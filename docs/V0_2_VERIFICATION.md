# v0.2 verification ledger

## Verified evidence as of this commit

### Production Dart and Flutter code, synthetic transport

Pipeline **2863893764**, SHA `0c21fe62ca42bc04b38dc3f41ee7747a60a3aee5`, Flutter job **16604477718**:

- **200 tests passed, 0 failed, 0 skipped, 0 errors**, from GitLab's JUnit report.
- Includes expanded GitLab pagination-header regressions, account isolation/cancellation, stream budgets, 30 write-operation contracts, 9 DELETE contracts, error/status/no-retry checks, validated unified-diff anchors and paginated state recovery.
- Includes issue and note CRUD executed through visible Flutter controls, failed-write draft retention and secure draft restoration.
- Includes 48 width/text-scale/theme layout checks and 8 actual Flutter-rendered synthetic-data screenshots.
- That pipeline was **not globally green**: a redundant import produced an analyzer info diagnostic. This commit removes the import; its successor pipeline must independently pass before merging or shipping the revised APK.

The network-widget harness now advances the fake clock and real event loop separately. It no longer considers settled animations alone proof that chained HTTP/cancellation work finished. No failing assertions were disabled. Previously skipped empty-body checks were replaced with explicit empty-body assertions.

### Live GitLab connector checks — distinct from the Dart smoke suite

Using the connected account, a dedicated temporary Unicode-path file was created/read/updated on this feature branch; an intentionally stale `last_commit_id` write returned HTTP 400; rereading proved the newer contents were not overwritten. The fixture was deleted and a final GET returned 404. No existing user file was overwritten.

On MR !1, a temporary synthetic note (ID **3868674928**) was created, listed/read, updated, reread, deleted with HTTP 204, and a final note listing confirmed it absent. These are actual server operations through the authorized connector, **not** a claim that the App's supplied-PAT HTTP transport or device UI was exercised against GitLab.

### NOT_RUN / not claimed

- Supplied-PAT production-Dart full live CRUD suite: **NOT_RUN**. The attempted credential injection was blocked before a pipeline was created. Do not encode, commit, expose or reroute credentials to evade the restriction.
- Independent-reviewer approval, enterprise reauthentication/SAML policy and cross-version self-hosted matrix: **NOT_RUN**.
- Android emulator/physical-device E2E, iOS compile/device E2E, app-store signing and delivery: **NOT_RUN**.
- No statement that all 105 planned operations have native UI or full integration evidence.

## Feature verification boundaries

| Area | Implemented native flow | Current evidence |
|---|---|---|
| Account/project list/private locator | PAT identity, scope separation, canonical IDs, safe pagination | Dart tests, synthetic widget renders; real connector membership response inspected |
| Projects | Private create, read, edit, star/unstar, confirmed delete | Transport contracts; full PAT live suite not run |
| Files/branches/tags | Read, file CRUD with last-commit checks, branch/tag create/delete | Transport tests; isolated real connector file CRUD and stale-write rejection |
| Issues/notes | CRUD, close/reopen, self-assignment, drafts | Stateful visible-control widget CRUD; isolated real connector MR-note CRUD |
| MR/review | CRUD, pinned diff, inline discussion, resolve, SHA approve/merge | Contract/parser/layout tests; independent approval and live App review not run |
| Pipelines/jobs | Run/read/retry/cancel/delete, logs, manual play | Contracts plus no-trace manual-job regression; no App live full-suite claim |
| Releases/labels/milestones | CRUD and state controls | Transport contracts; label `new_name` mapping checked against official API |
| Artifacts | Open GitLab in browser | Explicit fallback, not native artifact downloading |

## Release gate

The successor pipeline must pass Python checks, Flutter analyze, all Flutter tests and native-template checks before APK build. Only main publishes a preview. Report the exact merged commit, pipeline, build and package IDs when delivery actually succeeds. A green build does not convert NOT_RUN device/live checks into PASS.
