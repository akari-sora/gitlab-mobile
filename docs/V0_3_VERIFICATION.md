# v0.3 verification ledger

Evidence below was recorded on 2026-09-21/22, then extended with the pre-merge emulator walks and the merged `main` walk. It does not accept G0 or v0.3. Synthetic tests, live API checks, emulator runs and physical-device runs are separate. A Flutter test total in this file is the count read from that pipeline's JUnit report, not a promise.

`main` after !3, !7, !6, !8, !5 and !4 is `9183f19`. Pipeline `2869335026` reported `509` tests.

The Samsung walk used `db12b41`, which does not contain these merges. A behaviour was exercised only on the build named in that row.

## Merged into `main`

| MR | Branch | Head reviewed | Merge commit | Contents |
|---|---|---|---|---|
| !3 | `feat/mobile-v03-quick-wins` | `646dce9` | already recorded | Appearance persistence, merge options, overview review card, collapsed discussions |
| !7 | `feat/mobile-v03-editor` | `1068dbf` (approved on `eccf7b4`, rebased) | `3891577` | Label, assignee, reviewer and branch pickers; attachment upload (`POST /projects/:id/uploads`, multipart, 25 MiB); Markdown toolbar and 編輯／預覽 |
| !6 | `feat/mobile-v03-android` | `b3e05e9` (approved on `0d5f40e`, rebased) | `cbe589a` | Material You dynamic colour (switch in 我的, default on for Android), predictive back (`enableOnBackInvokedCallback`, `RouteExit.track`), edge-to-edge, launcher shortcuts (`inbox`, `search`, `recent:<projectId>:<sha256(accountKey#projectId)>`) |
| !5 | `feat/mobile-v03-artifacts` | `bfcc5e0` (Grok approved `e9e1965`, Codex approved `971228c`; CI-fix seam commit `4d02313` approved by both; rebased) | `fd14809` | In-app artifact download, collapsible job-log sections, card semantics (`MergeSemantics` button cards), 待刪除 badge |
| !4 | `feat/mobile-v03-review` | `92f8c9f` | `9183f19` | Auto-resume of the last active account; inline diff discussions |
| !8 | `feat/mobile-v03-polish` | `c90ca15` | `0c2522b` | `WorkshopColors` ThemeExtension, JetBrains Mono (OFL, bundled, licence registered), EntityCard / MetaChip / StatusBadge, monogram hue hashing, EmptyState, AppearancePicker, feed gutter on wide screens, dark control outlines |
| !10 | `fix/mobile-v03-release-blockers` | `f4dc42f` (round 3; Codex APPROVE, Grok APPROVE) | `e941a6a` | Share and picker cache copies removed (share_plus copy owned by the newest share, deleted after dismiss/failure, after the next resume on success, and on account removal); stale editor drafts held back with 套用草稿／捨棄草稿 (drafts store `__base` = `updated_at`); optional stable debug keystore for CI previews (`ANDROID_DEBUG_KEYSTORE_B64`) |
| !12 | `fix/mobile-v03-legacy-draft-hold` | `90f3be9` (Codex APPROVE, Grok APPROVE) | `98bfb21` | A draft with no `__base` (older build) is held back like a stale one when editing an existing resource, with its own notice; creation editors restore as before |
| !13 | `chore/mobile-v03-version-info` | `82982fa` (Grok APPROVE, Codex APPROVE after one MINOR) | `fb6a01a` | `pubspec` 0.3.0+3, `package_info_plus`; 我的 shows 「版本 0.3.0 (3) · commit …」 with a copy button; CI passes `--dart-define=GITLAB_MOBILE_COMMIT` |
| !14 | `feat/mobile-v03-attachment-reader` | `ddd9bc7` (round 3; Codex APPROVE, Grok APPROVE) | `56acd0d` | Project uploads in Markdown render as authenticated inline images (`GET /projects/:id/uploads/:secret/:filename`, page-scoped reference parser, per-document budget: 20 distinct previews, 24 MiB, 2 in flight, header dimension gate, bounded decode), full-screen viewer, identity-aware failure sheet with retry / account switch; editor preview included |

Inline discussions anchor only when base, start and head SHAs, the per-side paths, and the positive-integer coordinates all match. Threads that do not match are listed under 其他版本的討論. 查看程式碼 uses the same rule (`diffPositionLines`). Auto-resume re-validates `/user`. The last-account key is cleared only on a 401.

Artifact download: authenticated first hop with `followRedirects: false`, exactly one https `Location`, fetched by an isolated bare Dio with no credential headers, 256 MiB budget, throttled progress, then 開啟／分享.

## Verified evidence as of this commit

### Live private CRUD smoke

`tool/live_smoke.dart` ran the production Dart client against GitLab.com with the PAT of user **9571238**. It created an isolated private sandbox project **86719103**. Result: **33 PASS / 1 FAIL**. The report `smoke-output/report.json` is not committed. This run was repeated on `e941a6a` on 2026-09-22 (sandbox `gitlab-mobile-smoke-1790044336863608`, deleted by the tool): again **33 PASS / 1 FAIL**, the same `jobs.read_trace_retry_new_attempt_and_manual_play` check (the job trace never carried the marker: the sandbox job did not run; the failure reason was not captured this time), so `pipelines.retry_then_cancel_then_delete` again did not run. Not reclassified.

The FAIL is `jobs.read_trace_retry_new_attempt_and_manual_play`. The sandbox jobs never ran (`failure_reason=ci_quota_exceeded`): GitLab.com shared-runner compute quota for this namespace. That is a server-side limit. The check stays FAIL; it is not reclassified as a client pass.

A failing check aborts the checks that follow it. `pipelines.retry_then_cancel_then_delete` therefore did not run. The sandbox project was later marked for deletion. This run is the production client talking to GitLab. It is not the Flutter UI and not a physical device.

### Physical device

Samsung **SM-S9280** (Galaxy S24 Ultra), Android 16. Debug APK built from `db12b41` with `tool/bootstrap.py`.

Walked on that APK: fresh PAT sign-in, saved-account re-validation, member list, search, private project `torque` files and Markdown render, a public project's issues / merge-request list / CI list, pipeline → jobs → job log (10-second refresh, follow tail, retry / cancel / artifact menu), issue create with the Samsung keyboard (server-confirmed), comment create, secure draft restored after force-kill and relaunch, delete with the typed confirmation 「#7」 (server 404), light/dark chips, back navigation. Test issue #7 and its note were deleted.

Not walked on the phone: Inbox tab, the project More tab (更多), the ambiguous-404 screen.

The same phone, on the !3 build (commits `cf379ad`, `339320a`, `dd686f2`, `646dce9`), also walked: appearance persistence across force-kill, the MR overview review card, the merge-dialog switches (the dialog was cancelled; nothing was merged), and collapsed resolved discussions with the filter and summary.

Saved-account re-validation on the `db12b41` APK is not the !4 auto-resume path. The artifact menu on that APK opens GitLab in the browser.

The phone was reassigned after that !3 walk and released again on the morning of 2026-09-22. The same phone then ran the CI-published preview `gitlab-mobile-e941a6ac-debug.apk` (package version `e941a6ac…`, sha256 verified against `SHA256SUMS`; the old local build was uninstalled first because of the runner's debug signature): fresh PAT sign-in; `am force-stop` + relaunch landed on the project list with no tap; 新增議題 from the editor with title, 說明 and the 指派 picker created issue #9 with the assignee confirmed through the API; 編輯 → 附加圖片 → Android photo picker → a pushed PNG uploaded and the returned Markdown was saved to the server (`![…](/uploads/<secret>/….png)`), the picker's cache copy was deleted; the issue page showed that attachment as icon + alt on `e941a6ac` (the attachment reader is !14); native_templates job log with collapsible sections; 下載產物 → 開啟／分享 → the Samsung share sheet listed the archive and `cache/share_plus` was removed after dismissing it; inbox shortcut intent → 收件匣; Material You on Samsung produced a wallpaper-derived scheme in dark and light. Not exercised on the phone: the recent-project shortcut (the phone's `dumpsys shortcut` redacts ids), merging a merge request from the app, choosing a share target. After !14 merged, the phone took the CI preview `gitlab-mobile-56acd0d0-debug.apk` (package 70165146; an in-place `adb install -r` over the previous CI preview failed on the runner's changing debug signature, so the old build was uninstalled and the PAT entered again — the `ANDROID_DEBUG_KEYSTORE_B64` variable is still unset): 我的 showed 「版本 0.3.0 (3) · commit 56acd0d0」 with the copy button, and issue #9's uploaded image rendered inline through the authenticated upload endpoint; tapping it opened the full-screen viewer with 「在 GitLab 開啟」. Issue #9 was deleted afterwards.

### Emulator

Pixel_9, `emulator-5554`, Android 16. Per branch, before merge.

- **!5** (`9789033` / `e9e1965`): 83.4 MB `artifacts.zip` downloaded to completion with progress (about 1 MB/s after the throttle fix; the emulator NAT ceiling). 開啟／分享 and 在 GitLab 開啟 were shown. Collapsible job-log section headers showed durations on a real trace. The project list showed the 待刪除 badge.
- **!4** (`fa529a2`): a real positioned discussion on !3 `lib/core/workspace_api.dart` line 41 rendered under that line. Cold start landed on the project list without a tap.
- **!7**: screenshots of the label, assignee, reviewer and branch pickers, and of the Markdown toolbar.
- **Polish head `c90ca15`** (contains !3, !7, !6 and polish): fresh PAT sign-in. 我的 showed the appearance picker (跟隨系統／淺色／深色) and the Material You switch; dark mode rendered. Project files, issues and CI tabs used the new card grammar and JetBrains Mono SHAs. 新增議題 showed 編輯／預覽, an 8-action toolbar, and a label picker sheet with search and an empty state. Inbox todo cards rendered. `dumpsys shortcut` listed `inbox`, `search` and `recent:<id>:<digest>`. Cold start through the inbox shortcut intent went login → saved-account resume → 收件匣. Warm `search` focused the project search field. Warm recent opened the project directly. The generated manifest has `enableOnBackInvokedCallback="true"`.

### Merged `main`

`9183f19`: CI-published preview APK `gitlab-mobile-9183f196-debug.apk` (package 70139834, sha256 verified against `SHA256SUMS`) installed fresh on the Pixel_9 emulator (a locally signed build had to be uninstalled first: the registry APK carries the runner's debug signature). Fresh PAT sign-in wrote `gitlab_mobile_last_account_v1`; `am force-stop` + relaunch landed on the project list with no tap (auto-resume). 切換帳號 deleted the key; selecting the saved account wrote it again; relaunch resumed again. Job 下載產物 on a telltale job completed a 1.2 MB `artifacts.zip` in under 4 s with 開啟／分享 and 在 GitLab 開啟. The `python_checks` log of pipeline 2869335026 showed collapsible `prepare executor · 2 秒` / `prepare script · 0 秒` / `get sources` headers with the raw markers hidden, and a tap collapsed a section. The merged !3 discussion tab listed 13 threads with the 2 resolved ones collapsed and the 只看未解決 filter. Inline anchoring on merged `main` was not re-walked; its evidence is the `fa529a2` emulator run above (the anchoring code was rebased without logic changes).

- **!10 blocker build `f4dc42f`** (local debug APK, fresh install, PAT sign-in): a phone draft typed into an issue's 說明, the issue then edited via the API; reopening 編輯 from a freshly loaded page showed 「草稿來自較舊的版本，伺服器內容已在之後變更。」 with 套用草稿／捨棄草稿 and 儲存 disabled; 捨棄草稿 cleared the notice. Reopening from a page still holding the pre-edit data applied the draft as before; the save-time `updated_at` conflict check remains the guard on that path. 下載產物 → 開啟／分享 showed the system chooser with `cache/share_plus` present; dismissing it removed the directory. The temporary issue was deleted afterwards.

### Artifact transport

`GET /projects/:id/jobs/:id/artifacts` answers **302** to `https://cdn.artifacts.gitlab-static.net/...`. A single-file `…/artifacts/<path>` answers **200** directly. The !5 client takes the authenticated first hop with `followRedirects: false`, follows exactly one https `Location`, and fetches that hop with an isolated bare Dio that sends no credential headers. Budget is 256 MiB. Progress is throttled.

### Final release-readiness review

After !4 merged, an independent Codex gpt-6-astra (max) pass over `main` `9183f19` confirmed all thirteen items of the original external review present (item 10 partial), found no credential leak on the artifact redirect hop, OAuth rotation, multipart upload or launcher-shortcut paths, and returned **NOT READY** on three daily-use defects (plaintext share copies surviving account removal, plaintext picked-attachment copies, a persisted draft able to overwrite a newer server revision) plus the unstable debug signature of CI previews. !10 closes them (three review rounds: Codex REQUEST CHANGES → PARTIAL → APPROVE; Grok REQUEST CHANGES → APPROVE → APPROVE). The readiness pass was not re-run after !10.

### Second external review (2026-09-22)

A second external review of `e941a6a` confirmed the first review's gaps as closed on `main` and raised: a draft from an older build (no `__base`) still auto-applied (→ !12); attachments uploaded but never rendered or resolved in the app (→ !14); the app still reported 0.2.0 with no commit information (→ !13); the stable-signing hook exists but is unverified until the maintainer sets `ANDROID_DEBUG_KEYSTORE_B64` (still NOT_RUN); the full private workflow on the latest CI APK on the phone (partly done above; the live smoke re-run is recorded under the smoke section). Still deferred: account-switch retry of the failed target, a cross-project CI overview, a true two-pane layout, OAuth login, push, iOS.

### Dual review

Every feature MR is reviewed independently by Codex gpt-6-astra (reasoning max) and Grok 4.7 (xhigh). Blockers are fixed and re-reviewed incrementally before merge. That process is not an independent human review.

- !3: both APPROVE in round 2.
- !7: 3 rounds. Both APPROVE on `eccf7b4`.
- !6: 4 rounds. Both APPROVE on `0d5f40e`.
- !5: Codex REQUEST CHANGES in rounds 1–3, APPROVE in round 4 (`971228c`). Grok APPROVE in round 3 (`e9e1965`). Round 4 NEW-1 (legacy base64 cache directory) is closed as not applicable: that layout existed only on the unmerged branch and was never published.
- !4: Codex APPROVE in round 4 (`e65944e`) and round 5. Grok APPROVE in round 3, REQUEST CHANGES in round 4 (rollback must stay inside the untouched-list check), APPROVE in round 5 (`92f8c9f`).
- !8: Grok APPROVE in round 4. Codex resolved by inspection. MR pipeline 2869208422 on `c90ca15` (success) is the runtime evidence.

## Feature verification boundaries

| Feature | Implemented | Evidence | NOT_RUN |
|---|---|---|---|
| Appearance persistence (`gitlab_mobile_appearance_v1`, `<ThemeMode.name>\|<0\|1>`; a bare !3 mode name still decodes) | !3, merged; dynamic-colour flag added by !6 | Phone, !3 build, restored after force-kill. Emulator `c90ca15`: 跟隨系統／淺色／深色 and the Material You switch; dark mode rendered | iOS; reinstall / backup migration. The phone walk had no dynamic-colour flag |
| Merge squash / remove-source-branch | !3, `339320a` | Phone: switches shown; dialog cancelled | A merge that completes with either switch on |
| MR overview review card | !3, `339320a` | Phone: card shown | Approve or merge from the card |
| Collapsed resolved discussions | !3, `dd686f2`, review fixes `646dce9` | Phone: collapsed threads, filter, summary | Device matrix beyond this phone |
| Auto-resume last account (`gitlab_mobile_last_account_v1`; sign-out marker `gitlab_mobile_sign_out_pending_v1`; key cleared only on 401) | !4, `92f8c9f`, merge `9183f19` | Emulator `fa529a2`: cold start on the project list, no tap. Emulator `c90ca15`: inbox-shortcut cold start → login → saved-account resume → 收件匣 | Physical phone. `db12b41` re-validation is a different path |
| Inline diff discussions (SHA, per-side path, positive-int coordinates; 其他版本的討論; `diffPositionLines`) | !4, `92f8c9f` | Emulator `fa529a2`: discussion under !3 `lib/core/workspace_api.dart` line 41 | Physical phone. Creating a line discussion. Opening 其他版本的討論 or 查看程式碼 was not part of that note |
| In-app artifact download | !5, `bfcc5e0`, merge `fd14809` | Emulator `9789033` / `e9e1965`: 83.4 MB `artifacts.zip` completed, progress, 開啟／分享, 在 GitLab 開啟 | Physical phone. The `db12b41` artifact menu opened the browser |
| Log sections | !5 | Emulator: collapsible section headers with durations on a real trace | Physical phone |
| Card semantics (`MergeSemantics` button cards) | !5 | Code on the merged MR | TalkBack / VoiceOver. Physical phone |
| Pending-deletion badge | !5 | Emulator: 待刪除 on the project list | Physical phone (`db12b41`) |
| Pickers (label, assignee, reviewer, branch) | !7, `1068dbf`, merge `3891577` | !7 emulator screenshots. Emulator `c90ca15`: label sheet with search and empty state | Live assign. Physical phone |
| Attachment upload | !7 | Merged client (`POST /projects/:id/uploads`, multipart, 25 MiB) | Live upload. Physical phone. The !7 screenshots are the pickers and the toolbar |
| Markdown toolbar and 編輯／預覽 | !7 | !7 toolbar screenshots. Emulator `c90ca15`: 編輯／預覽 and the 8-action toolbar on 新增議題 | Physical phone. Phone issue text on `db12b41` used the Samsung keyboard |
| Material You dynamic colour | !6, `b3e05e9`, merge `cbe589a` | Emulator `c90ca15`: switch in 我的; dark mode rendered | Physical phone |
| Predictive back | !6 | Emulator `c90ca15`: generated manifest `enableOnBackInvokedCallback="true"` | A predictive-back gesture. Physical phone. `db12b41` back navigation is a different build |
| Edge-to-edge | !6 | Merged client | A visual check of insets. Physical phone |
| Launcher shortcuts (`inbox`, `search`, `recent:<projectId>:<sha256(accountKey#projectId)>`; `recent_project.v1.<base64url(account.key)>`) | !6 | Emulator `c90ca15`: `dumpsys shortcut` listed the three types; cold inbox shortcut; warm search focused the field; warm recent opened the project | Physical phone |
| Polish (WorkshopColors, JetBrains Mono, EntityCard / MetaChip / StatusBadge, monogram hue, EmptyState, AppearancePicker, feed gutter, dark outlines) | !8, `c90ca15`, merge `0c2522b` | Emulator `c90ca15`: appearance picker, card grammar, JetBrains Mono SHAs, dark mode, editor, inbox cards | Physical phone. The feed gutter is not a two-pane layout |

## NOT_RUN / not claimed

- OAuth login. PKCE is implemented. `oauthApplicationIdFor` is empty. Registering an Application ID is a maintainer action.
- Push delivery.
- iOS. Deferred by the maintainer.
- App Store / Play signing. The phone package was a debug APK.
- Independent human review. The dual LLM rounds above are a separate process.
- On the phone: the recent-project launcher shortcut, merging a merge request from the app, choosing a share target, and a stable-signature in-place upgrade (`ANDROID_DEBUG_KEYSTORE_B64` not set). The `e941a6ac` phone walk above covers the rest of v0.3.
- Full-suite live CI job control. The one job trace / retry / manual-play check failed in both runs (the sandbox job never ran), and pipeline retry / cancel / delete did not run.
- TalkBack / VoiceOver.
- Android/iOS device matrix beyond one phone and one emulator.
- Cross-project CI overview.
- Two-pane wide layout.
- Failed-target retry across an account switch.
- Ambiguous-404 screen and the project More tab on a device.
- Reinstall / backup migration of secure storage.

## Release gate

Do not mark G0 or v0.3 accepted from this file. !3, !7, !6, !8, !5, !4, !10, !12, !13 and !14 are merged; `main` is `56acd0d`. Pipeline `2869927924` reported `561` tests (pipeline `2869335026` on `9183f19` reported 509). That is the observed JUnit count for that pipeline. A pipeline must pass the Python checks, Flutter analyze and Flutter tests before an APK build. Only successful `main` pipelines publish a preview. Pipeline `2869335026` published generic package `gitlab-mobile-preview` version `9183f19616258a9e913759bcb371695f0a0ae41a` (package id 70139834): `gitlab-mobile-9183f196-debug.apk`, 177,861,646 bytes, with `build-metadata.json` and `SHA256SUMS`. Pipeline `2869927924` published version `56acd0d0d2730d87e6b47fe43fee3b7659d6428b` (package id 70165146): `gitlab-mobile-56acd0d0-debug.apk`, the build the phone walk below installed. Debug signing is not store signing. The live smoke re-run is recorded above. The merged-`main` emulator walk is CI-published preview APK `gitlab-mobile-9183f196-debug.apk` (package 70139834, sha256 verified against `SHA256SUMS`) installed fresh on the Pixel_9 emulator (a locally signed build had to be uninstalled first: the registry APK carries the runner's debug signature). Fresh PAT sign-in wrote `gitlab_mobile_last_account_v1`; `am force-stop` + relaunch landed on the project list with no tap (auto-resume). 切換帳號 deleted the key; selecting the saved account wrote it again; relaunch resumed again. Job 下載產物 on a telltale job completed a 1.2 MB `artifacts.zip` in under 4 s with 開啟／分享 and 在 GitLab 開啟. The `python_checks` log of pipeline 2869335026 showed collapsible `prepare executor · 2 秒` / `prepare script · 0 秒` / `get sources` headers with the raw markers hidden, and a tap collapsed a section. The merged !3 discussion tab listed 13 threads with the 2 resolved ones collapsed and the 只看未解決 filter. Inline anchoring on merged `main` was not re-walked; its evidence is the `fa529a2` emulator run above (the anchoring code was rebased without logic changes). A green build does not turn a NOT_RUN device, live, or iOS check into PASS.
