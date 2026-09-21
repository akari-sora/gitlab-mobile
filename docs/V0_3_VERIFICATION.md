# v0.3 verification ledger

Evidence below was recorded on 2026-09-21/22. It does not merge merge requests !3–!7, and it does not accept G0 or v0.3. Synthetic tests, live API checks, emulator runs and physical-device runs are separate. Flutter test totals are read from the CI job report; this file does not hard-code them.

`main` at the phone build SHA `db12b41` does not contain !3–!7. A behaviour named with an MR was exercised only on the build named in that row.

## Verified evidence as of this commit

### Live private CRUD smoke

`tool/live_smoke.dart` ran the production Dart client against GitLab.com with the PAT of user **9571238**. It created an isolated private sandbox project **86719103**. Result: **33 PASS / 1 FAIL**. The report `smoke-output/report.json` is not committed.

The FAIL is `jobs.read_trace_retry_new_attempt_and_manual_play`. The sandbox jobs never ran (`failure_reason=ci_quota_exceeded`): GitLab.com shared-runner compute quota for this namespace. That is a server-side limit. The check stays FAIL; it is not reclassified as a client pass.

A failing check aborts the checks that follow it. `pipelines.retry_then_cancel_then_delete` therefore did not run. The sandbox project was later marked for deletion. This run is the production client talking to GitLab. It is not the Flutter UI and not a physical device.

### Physical device

Samsung **SM-S9280** (Galaxy S24 Ultra), Android 16. Debug APK built from `db12b41` with `tool/bootstrap.py`.

Walked on that APK: fresh PAT sign-in, saved-account re-validation, member list, search, private project `torque` files and Markdown render, a public project's issues / merge-request list / CI list, pipeline → jobs → job log (10-second refresh, follow tail, retry / cancel / artifact menu), issue create with the Samsung keyboard (server-confirmed), comment create, secure draft restored after force-kill and relaunch, delete with the typed confirmation 「#7」 (server 404), light/dark chips, back navigation. Test issue #7 and its note were deleted.

Not walked on the phone: Inbox tab, the project More tab (更多), the ambiguous-404 screen.

The same phone, on the !3 build (commits `cf379ad`, `339320a`, `dd686f2`, `646dce9`), also walked: appearance persistence across force-kill, the MR overview review card, the merge-dialog switches (the dialog was cancelled; nothing was merged), and collapsed resolved discussions with the filter and summary.

Saved-account re-validation on the `db12b41` APK is not the !4 auto-resume path. The artifact menu on that APK opens GitLab in the browser.

### Emulator

Pixel 9 emulator, Android 16, arm64, build `feat/mobile-v03-artifacts`. Walked: PAT sign-in, project list with the 「待刪除」 badge, and the in-app artifact download sheet for `artifacts.zip` (83.3 MB) with progress and cancel. Throughput in that build was about 100 KB/s because the UI rebuilt per chunk; that is being fixed. Completion of the download, opening the file, and a physical-device download are not part of this note.

An ANR, 「Application does not have a focused window」, appeared once on the first cold start of a debug build on the emulator. It was not reproduced after restart. One occurrence is not a classified product defect.

### Artifact transport

`GET /projects/:id/jobs/:id/artifacts` answers **302** to `https://cdn.artifacts.gitlab-static.net/...`. A single-file `…/artifacts/<path>` answers **200** directly. The !5 client follows exactly one https `Location` and does not send credential headers on that hop.

### Dual review

Every feature MR is reviewed independently by Codex gpt-6-astra (reasoning max) and Grok 4.7 (xhigh). Blockers are fixed and re-reviewed incrementally before merge. !3 received APPROVE from both in round 2. That process is not an independent human review.

### Open merge requests at the time of writing

| MR | Branch / tip | Contents |
|---|---|---|
| !3 | `feat/mobile-v03-quick-wins` @ `646dce9` | Appearance persistence, merge options, overview review card, collapsed discussions. Auto-merge armed. |
| !4 | `feat/mobile-v03-review` @ `082ad8c` | Auto-resume of the last account, inline diff discussions. |
| !5 | `feat/mobile-v03-artifacts` @ `b24a136` | In-app artifacts, log sections, card semantics, deletion badge. |
| !6 | `feat/mobile-v03-android` @ `187f534` | Material You dynamic colour, predictive back, edge-to-edge, launcher shortcuts. |
| !7 | `feat/mobile-v03-editor` @ `b4ed2aa` | Pickers, attachment upload, Markdown toolbar. |

`feat/mobile-v03-polish` follows !6. It has no separate evidence in this ledger.

## Feature verification boundaries

| Feature | Implemented | Evidence | NOT_RUN |
|---|---|---|---|
| Appearance persistence (`gitlab_mobile_appearance_v1`) | !3, `cf379ad` | Same phone, !3 build, restored after force-kill | iOS; reinstall / backup migration. Dynamic colour is !6 and was not on this walk |
| Merge squash / remove-source-branch | !3, `339320a` | Same phone: switches shown; dialog cancelled | A merge that completes with either switch on |
| MR overview review card | !3, `339320a` | Same phone: card shown | Approve or merge from the card |
| Collapsed resolved discussions | !3, `dd686f2`, review fixes `646dce9` | Same phone: collapsed threads, filter, summary | Device matrix beyond this phone |
| Auto-resume last account | !4, `082ad8c`, key `gitlab_mobile_last_account_v1` | Code on the MR | Physical device, emulator, live sign-in through this path |
| Inline diff discussions | !4, `082ad8c` | Code on the MR | Device walk; creating a line discussion on a phone |
| In-app artifact download | !5, `b24a136` | Pixel 9 emulator: sheet, 83.3 MB `artifacts.zip`, progress and cancel, ~100 KB/s | Finished download, share/open, physical device. Phone artifact menu was the `db12b41` browser path |
| Log sections | !5 | Code on the MR | Device and emulator walk of the sections |
| Card semantics | !5 | Code on the MR | Device and emulator walk |
| Pending-deletion badge | !5 | Pixel 9 emulator: 「待刪除」 on the project list | Physical phone (`db12b41` build) |
| Pickers (label, assignee, reviewer, branch) | !7 | Code on the MR | Device, emulator, live assign |
| Attachment upload | !7 | Code on the MR | Device, emulator, live upload |
| Markdown toolbar | !7 | Code on the MR | Device and emulator. Phone issue text used the Samsung keyboard on `db12b41` |
| Material You dynamic colour | !6 | Code on the MR | Device and emulator. Phone light/dark chips were not this path |
| Predictive back | !6 | Code on the MR | Device and emulator. Phone back navigation was the `db12b41` build |
| Edge-to-edge | !6 | Code on the MR | Device and emulator |
| Launcher shortcuts | !6, recent-project record `recent_project.v1.<base64url(account.key)>` | Code on the MR | Device and emulator; launching from a shortcut |

CI results for these MRs are read from each job's report. This ledger does not restate them.

## NOT_RUN / not claimed

- OAuth login with a real Application ID. PKCE is implemented on !2 (`62b81fd`); `oauthApplicationIdFor` is an empty map, so the path stays inert.
- Push delivery.
- iOS as a product. An incidental `flutter build ios --simulator --no-codesign` (Xcode 26.3) succeeded. The maintainer has deferred iOS. No simulator UI run, device run, or signing is claimed.
- App Store / Play signing. The phone package was a debug APK.
- Independent human reviewer. Dual LLM review is a separate process; !3's two APPROVEs are not a human sign-off.
- Full-suite live CI job control. The one job trace / retry / manual-play check failed on quota, and pipeline retry / cancel / delete did not run.
- Ambiguous-404 screen, Inbox, and the project More tab on a device.
- Android/iOS device matrix beyond one phone and one emulator.
- TalkBack / VoiceOver, store delivery, and accepting auto-merge as a completed merge.

## Release gate

Do not mark G0 or v0.3 accepted from this file. !3–!7 were open when it was written. A pipeline must pass the Python checks, Flutter analyze and Flutter tests before an APK build; the test total is read from that job's JUnit report. Only successful `main` pipelines publish a preview. Debug signing is not store signing. When delivery succeeds, report the merged commit, pipeline, build and package IDs. A green build does not turn a NOT_RUN device, live, or iOS check into PASS.
