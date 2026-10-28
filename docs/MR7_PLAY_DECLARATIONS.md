# MR7 Play declarations: technical answers and local artifact receipt

Status: **DRAFT / no submission**. Prepared on 2026-10-29 (Asia/Taipei;
local command receipts use 2026-10-28 UTC). All store-facing wording is
**lead to phrase**. This is the 7C technical handoff under
[MR7 breakdown §6](plans/mr7-breakdown.md#6-7c-play-聲明與官方政策查閱-2026-10-28),
decisions 7-D6/7-D10 and coverage rows 11/15/22/23/27/28.

The checked-out source is `90dea7e8e113592e6d994279d0790e6e74a2dba5`,
branch `docs/mr7-7c-play`. No tracked application code, CI, localization, store listing or canonical
signing configuration is changed by this packet. `MERGELINE_AI_ASSISTANT` and
`MERGELINE_AI_BACKGROUND` both default to **false** in
`lib/features/ai/ai_gate.dart:2`; Play AI remains off under 7-D10. Enabling
GitLab-channel AI elsewhere would not enable Play or close any Play gate.

## 1. Build identity and artifact readback

These are fresh local builds from this checkout, using `lib/main.dart`, the
committed dependency lock and the existing `CURRENT_LOCAL` development signer.
They are not upload-key-signed bundles, Play App Signing outputs, CI artifacts
or device acceptance. No new key, rotation, account operation or upload was
performed. The public inventory and signing instructions were read before
packaging; the canonical directory was `0700`, with the existing keystore and
properties both `0600`, and `python3 tool/android_signing.py verify` passed.

| Build input | Observed value |
|---|---|
| Flutter / Dart | 3.47.2 / 3.13.2; framework `d3b14c8769`, engine `a804b26164` |
| `pubspec.lock` SHA-256 | `4dffbb4cd5e24e6108e46f4dad9879901aae95720515101d32149cfdf2f40a7e` |
| Version | `0.5.0`, versionCode `5` (local pubspec value, not a CI IID) |
| Android tools used for raw readback | Existing SDK build-tools `36.0.0`; command-line-tools `latest` |
| Public certificate SHA-256 | `a15c11c804bd8b40cebf052747bfea91542568989af0b7a092efcfcb7ebff434` |
| Debug defines | Explicit `MERGELINE_AI_ASSISTANT=false`, `MERGELINE_AI_BACKGROUND=false` |
| Release defines | Neither AI define supplied by the existing C8 release builder; both use their false defaults |
| QA / benchmark options | No `MR6C_QA`, `EMULATOR_UI_QA`, `EMULATOR_PERF_QA` or `PERF_DIAGNOSTICS` define supplied; normal production entrypoint |
| Distribution | All four APKs `local-only`; no pipeline/job or public download URL created |

| Flavor / variant | Application ID | Bytes | SHA-256 | Debuggable | Retained APK |
|---|---|---:|---|---|---|
| gitlab-debug | `io.gitlabmobile.gitlab_mobile` | 192912275 | `77a6283c601d31ff412727c74c92e7e7d1bc6ee58e99d06e12388ecc33f8ed90` | true | [app-gitlab-debug.apk](../../evidence/apks/app-gitlab-debug.apk) |
| play-debug | `app.mergeline` | 193071234 | `1b0ae07c083a6918b227832027eddb4797704eae98143f89aacf6371174f5b84` | true | [app-play-debug.apk](../../evidence/apks/app-play-debug.apk) |
| gitlab-release | `io.gitlabmobile.gitlab_mobile` | 95804463 | `0f1dcfa3e880f26b3184c313755f32f4a4cbc77cdcf801f0dca8d113c7a21149` | false | [app-gitlab-release.apk](../../evidence/apks/app-gitlab-release.apk) |
| play-release | `app.mergeline` | 95821821 | `e66b66d9997d405837638369d9ed5c5c0ca4946ca001c8850fd16f76172aff2b` | false | [app-play-release.apk](../../evidence/apks/app-play-release.apk) |

All four APKs verify under **v2** with the same expected certificate. Raw
`apksigner` reports v1, v3, v3.1 and v4 as false; no other verified
scheme or store-signing identity is claimed. All include `arm64-v8a`,
`armeabi-v7a` and `x86_64`. `artifact-survey.json` confirms that each
flavor's debug/release requested permission sets are identical.

The table and [retained packaging receipt](../../evidence/packaging-receipt.json)
record these local artifacts. The release-inventory index is owned
by 7R; its link to this receipt remains a lead/7R handoff item. Existing
inventory rows were not edited or used as evidence for these new APKs.

### 1.1 Complete merged permission sets

The following are the complete requested sets, cross-checked between packaged
`apkanalyzer manifest print`, `aapt2 dump permissions` and the actual merger
reports. `android.permission.` prefixes are written in full deliberately.
The build/variant comparison and command outcomes are recorded below.

| Permission | GitLab | Play | Actual merged source / feature |
|---|---|---|---|
| `android.permission.INTERNET` | Yes | Yes | Generated main manifest (`tool/bootstrap.py:182`); GitLab and enabled-provider network access. Debug template also merges the same permission. |
| `android.permission.FOREGROUND_SERVICE` | Yes | Yes | Generated main manifest (`tool/bootstrap.py:399`); Android agent-run service. Remains declared with background disabled. |
| `android.permission.FOREGROUND_SERVICE_DATA_SYNC` | Yes | Yes | Same generator; type-specific permission for the declared `dataSync` service. |
| `android.permission.POST_NOTIFICATIONS` | Yes | Yes | Generator plus `flutter_local_notifications` merged manifest; run status/stop notifications; runtime permission behavior untested here. |
| `android.permission.VIBRATE` | Yes | Yes | `flutter_local_notifications` merged manifest, pinned Dart package 22.3.3; notification support. Presence does not prove an actual vibration. |
| `android.permission.USE_BIOMETRIC` | Yes | Yes | `local_auth_android` plus `androidx.biometric:biometric:1.1.0`; optional app lock. No biometric template is uploaded by this flow. |
| `android.permission.USE_FINGERPRINT` | Yes | Yes | `androidx.biometric:biometric:1.1.0`; compatibility app-lock authentication. |
| `android.permission.ACCESS_NETWORK_STATE` | Yes | Yes | `androidx.media3:media3-common:1.9.2` / `media3-exoplayer:1.9.2`; existing media playback network handling. |
| `android.permission.WAKE_LOCK` | Yes | Yes | `androidx.media3:media3-exoplayer:1.9.2`; existing media playback support. |
| `android.permission.REQUEST_INSTALL_PACKAGES` | Yes | **Absent** | Generated `src/gitlab/AndroidManifest.xml`, from the GitLab updater section of `tool/bootstrap.py`; user-confirmed APK installation only on GitLab channel. |
| `io.gitlabmobile.gitlab_mobile.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` | Yes | Absent | `androidx.core:core:1.18.0`; GitLab application-scoped receiver protection. Also defined with signature protection (`0x2`). |
| `app.mergeline.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` | Absent | Yes | Same AndroidX source, resolved to the Play application ID; also defined with signature protection (`0x2`). |

Thus GitLab requests **11** permissions and Play **10**. The permission
definition is not an extra requested permission. `android.permission.DUMP`
appears as protection on AndroidX's exported profile installer receiver, not
as a requested permission. No `uses-permission-sdk-23` conditional set is
present. Artifact checks also cover absence of boot, exact-alarm, full-screen
intent, camera, microphone and broad storage/media-read permissions. Picker
intent queries (`GET_CONTENT`) are not storage permission grants.

### 1.2 SDK, service, backup, cleartext and exported components

| Field | Technical answer for both flavors |
|---|---|
| min / target / compile SDK | `24 / 36 / 36`, from each APK's manifest/badging; Java/Kotlin target and AGP are checked by the existing bootstrap artifact guard. |
| FGS | Exactly one `io.gitlabmobile.gitlab_mobile.AgentRunService`; `foregroundServiceType=dataSync` (packaged numeric `0x1`), `exported=false`, `stopWithTask=true`. No boot start receiver. |
| Backup / transfer | `allowBackup=false`; packaged `fullBackupContent` and `dataExtractionRules` refer to the generated exclusion XML. Android backup/restore and device-transfer behavior are **NOT_RUN**. |
| Cleartext | `usesCleartextTraffic=false`. This does not prove Dart/native socket enforcement; see §3.4. |
| Exported activities | `MainActivity` (launcher and OAuth callback) and `LinkActivity` (HTTPS `gitlab.com` / text-share trampoline). Both remain intentional exported entrypoints. |
| Other exported component | `androidx.profileinstaller.ProfileInstallReceiver`, guarded by `android.permission.DUMP`; this is AndroidX profile installation, not an app QA channel. |
| Other services | `com.google.android.gms.metadata.ModuleDependencies` is disabled and nonexported; photo-picker backport metadata. |
| Nonexported providers | Image picker, share and AndroidX startup providers in both flavors. `UpdateFileProvider` exists **only in GitLab**, with authority `io.gitlabmobile.gitlab_mobile.updates` and URI grants for the updater cache. |
| Other nonexported components | SharePlus pending-intent receiver and URL-launcher WebView activity in both; Play additionally has nonexported `PlayCoreDialogWrapperActivity`. |
| QA components | No QA/benchmark Android component declared. Debug native QA adapter code and release code isolation are separate questions below. |

### 1.3 QA / benchmark boundary and limitations

`tool/bootstrap.py:989` generates `AgentRunQaAdapter` under `src/debug`.
The native registration in `tool/bootstrap.py:652` attempts reflective loading
and debug builds can install an inert `io.gitlabmobile/agent_runs_qa` channel.
Consequently **do not claim that debug APKs contain no QA channel/adapter**.
Normal `lib/main.dart` is distinct from the explicit C8 and emulator QA
entrypoints. No QA entrypoint or enabling define was used for these APKs.

| APK | Native C8 result | Defined DEX classes | QA adapter defined | Pre-R8 inputs |
|---|---|---:|---|---|
| gitlab-debug | `NATIVE_CHECKS_PASS` | 18502 | true | Not an R8 release build |
| play-debug | `NATIVE_CHECKS_PASS` | 18969 | true | Not an R8 release build |
| gitlab-release | `NATIVE_CHECKS_PASS` | 2781 | false | Same-invocation R8 capture; see below |
| play-release | `NATIVE_CHECKS_PASS` | 2816 | false | Same-invocation R8 capture; see below |

Both releases have fresh `:app:minify<Flavor>ReleaseWithR8` execution,
complete captured program/feature inputs, same-build mapping and final
APK hash bindings. The C8 guard found no QA/integration-test classes in
those release inputs/mappings/defined DEX classes and verified compiled
`AgentRunService.onTimeout(int,int)` / `onDestroy()` methods. Evidence:
`release-builds.json`, `release-builds-r8-<flavor>/receipt.json` and
`c8-artifacts.json` in the evidence directory. The captured input counts
are 14,259 (GitLab) and 14,717 (Play); these are inputs, not final DEX counts.

| Release | R8 dump SHA-256 | Mapping SHA-256 |
|---|---|---|
| gitlab | `02824075debb77b60c584306054f1958dd86fa6dc1bf569b457aced09049af6a` | `56c159d69fea25bf1c07772ff2024f3f098c6061287e03e6f2e4f26f55d3e5fe` |
| play | `b1606a23e09b934d8ecfa6bca319bf77748569d65b24c0598e95eacc5b9bd52e` | `9f557e5fbe44d40c246a133c1ca942c4caf3551fc4d44e5fb50e15ae18b84686` |

The additional `artifact-survey.json` scan examined all packaged DEX plus
each release ABI's `libapp.so` (debug: `kernel_blob.bin`). Neither release
matched the six known QA/integration/performance literals recorded there.
Both debug APKs **do** contain `io.gitlabmobile/agent_runs_qa` and
`plugins.flutter.io/integration_test` in DEX, and `PERF_DIAGNOSTICS` in
the debug kernel. These observations are not an enabled-runtime claim.
`source-qa-support.log` records the supporting source grep.

The C8 readback command exited **1**, overall `NOT_VERIFIED`, despite
all four `NATIVE_CHECKS_PASS` results: its explicit remaining boundary is
`dart_aot_qa_handler=NOT_VERIFIED`, with `device_os=NOT_RUN`.

Release DEX/mapping/compiler-input checks establish only their stated native
boundary. A negative string search alone cannot establish that optimized Dart
AOT contains no reachable QA/benchmark handler. The existing C8 tool keeps
`dart_aot_qa_handler=NOT_VERIFIED`; that complete release gate remains open.
Source greps and absence of build defines support the receipt but do not
replace artifact evidence or a runtime channel probe. No emulator was used.

## 2. FGS declaration field draft (`dataSync`)

All entries below are technical inputs; **lead to phrase** the final Console
description. Manifest presence still needs review while the background flag
is false. No approval or video is claimed.

| Declaration field | Technical answer / evidence |
|---|---|
| Type / permission | Candidate `dataSync`; `FOREGROUND_SERVICE` and `FOREGROUND_SERVICE_DATA_SYNC` are present in both flavors. Type applicability and Play acceptance remain unapproved. |
| Feature | If enabled after its gates, one user-started AI/GitLab network run: selected-provider inference, allowed GitLab reads and separately authorized writes/uploads while the user briefly leaves the app. No scheduled or boot-initiated always-running agent. |
| User trigger | User starts a run in the app with the current account, recipient consent and allowed scope; show that exact sequence in the recording. The default-off APKs in this receipt cannot serve as an enabled-feature demonstration. |
| Why immediate work | The user is waiting for the requested result. Deferral delays that result and dependent reads/confirmations; it does not establish urgency such as medical or emergency processing. |
| Interruption effect | A partial answer/transfer can stop. An already-dispatched write can be uncertain; cancellation cannot undo an accepted GitLab write. A later resume requires the existing validity/permission checks and must not blindly repeat provider billing or GitLab dispatch. |
| User awareness / control | Generic progress/stop notification, current run UI and return-to-foreground confirmation are intended controls. Native notification channel `ai_runs_v1` is low importance with a private display and generic public version (`tool/bootstrap.py:529`). Actual allow/deny, channel disabled, lock-screen redaction and stop behavior require device evidence. |
| Video link | **NOT_RUN / no URL**. Record the actual enabled candidate and matching account-safe synthetic run; show explicit start, status notification, Home/background, stop/cancellation and return-to-foreground confirmation. Identify flavor, version, defines, SHA and device/API; do not use private content or keys. Include interrupted/uncertain outcome and timeout evidence separately. |
| Android platform constraints | Target 36: target-35+ restrictions apply, including no `BOOT_COMPLETED` dataSync launch and the shared six-hour background allowance in a 24-hour period. `onTimeout(int,int)` must stop promptly. The app's shorter active-run budget does not prove OS timeout handling. |
| Fallback if rejected | Keep `MERGELINE_AI_BACKGROUND=false` at the existing 7A2 boundary. Foreground-only AI may be considered only after its own gates; keep the whole assistant off if a safe separation cannot be proved. Do not silently switch to `specialUse` or claim UIDT eligibility. Any manifest removal is a separate lead-owned implementation decision. |

Official references, accessed 2026-10-29:
[Play FGS declaration](https://support.google.com/googleplay/android-developer/answer/13392821?hl=en),
[Android service types](https://developer.android.com/develop/background-work/services/fgs/service-types),
[Android timeout behavior](https://developer.android.com/develop/background-work/services/fgs/timeout).
The corresponding C8 V1–V12 device rows, actual demo and Console review are
**NOT_RUN** in this packet.

## 3. Data safety: field-by-field technical draft

This inventory covers the implemented GitLab client plus the conditional AI
flows. AI prompt/provider/report flows are not enabled by these default-off
builds. Before submission, scope the form to all distributed Play versions and
their actual reachable features. A future AI-on artifact needs a refreshed
inventory. BYO keys, user-selected servers and ephemeral processing do not
automatically remove a flow from assessment.

### 3.1 Form-wide fields

| Field | Conservative technical answer / open item |
|---|---|
| Collects user data? | **Yes, draft** for off-device GitLab account/authentication and user-content operations. Conditional AI flows add recipients/content if enabled. Do not claim all data remains on-device. |
| Shares user data? | Off-device recipients are enumerated below. **Draft Yes wherever an applicable exception has not been established.** Service-provider and user-initiated-transfer exceptions need flow-specific evidence; user selection alone does not settle every recipient or router's use. Final checked boxes: lead to determine against the current form. |
| Purpose choices | App functionality for GitLab/AI/media; Account management for sign-in; Fraud prevention, security and compliance for authentication/report handling where applicable. No evidence here justifies advertising, personalization or app analytics collection. |
| Required vs optional | Evaluate a whole data type across all flows and all users, regions and devices. Required authentication/identity must not be labelled optional merely because AI is optional. Feature choice is recorded below; a type-level Optional answer remains unapproved until that all-users check is complete. |
| Ephemeral processing | Do not assert universal ephemeral processing. GitLab stores posted content; provider logs, state, training or safety exceptions vary. The default local history period is unrelated to recipient retention. |
| Encryption in transit | **No / not established for an AI-enabled configuration allowing off-device LAN HTTP.** For this AI-off Play candidate, HTTPS-only GitLab source policy is supporting evidence; an all-flows Yes still requires an exact-artifact network/SDK review. Do not infer it from the manifest flag. |
| User deletion mechanism | Local clear/history/provider/account-removal controls exist; they do not delete provider logs or already-uploaded GitLab content. External deletion depends on recipient/admin APIs and terms. Public privacy-policy, deletion-request URL and contact wording are **lead to phrase / not verified**. |
| App account creation / account deletion question | Existing GitLab-account sign-in and OAuth token exchange are implemented. Do not equate removing a device credential with deleting a GitLab account. Lead must check the currently applicable form scope and supply any required external deletion route. No Console answer was submitted. |
| Independent security review / other certifications | **NOT_RUN**; none asserted by these builds or source tests. |

The form's category names are candidates below; credentials have no invented
standalone category. Map their actual fields to the current Personal info /
Other info options at submission. This packet did not open the Console.

### 3.2 Off-device data, recipients, purpose and sharing

| Flow | Data types / recipient | Collection / sharing assessment and purpose | Source evidence |
|---|---|---|---|
| A. AI prompt and tool context, conditional on AI enablement | Other in-app messages; Other user-generated content; Files and docs. Prompts, conversation turns, selected code, permitted issue/MR/discussion/diff/job-log excerpts and tool results go to the selected endpoint; routers may forward to a downstream model provider. Names, email and User IDs need their Personal info categories when actually present. | Off-device collection candidate; sharing exception unverified for each provider/router. App functionality. Redaction is not a promise that all private content is removed. | `lib/core/ai/ai_wire_client.dart:69` and `lib/core/ai/ai_transport.dart:91`; context in `lib/features/ai/ai_chat_controller.dart`; consent in `lib/features/ai/ai_consent_dialog.dart:13`. |
| B. AI attachment metadata, conditional | Attachment ID / placeholder, redacted filename, byte length and MIME/media type go to the AI endpoint. Files and docs / relevant content metadata; any residual identifying filename text needs corresponding categorization. | **Metadata leaves the device.** Same collection/sharing assessment and purpose as A. Actual selected attachment bytes are excluded from this provider-metadata contract. | `lib/features/ai/ai_attachment_session.dart:643` constructs the explicit untrusted metadata block. |
| C. Provider authentication, conditional | Provider API key in the configured authentication header, when applicable: Bearer `Authorization`, `api-key` or `x-api-key`; keyless auth is also supported. Protocol/model/usage parameters also reach the endpoint. Credential classification must follow the actual form; do not treat it as a device identifier. | Off-device authentication collection candidate; recipient is the configured provider, not a developer-operated proxy. App functionality / account management / security as applicable. Never put keys in examples or attach them to reports. | `lib/core/ai/ai_transport.dart:326`; endpoint/auth styles in `lib/core/ai/ai_provider.dart`; local key binding documented in `CLAUDE.md` Persistence. |
| D. GitLab identity and authentication | PAT or OAuth authorization/refresh material goes to the selected HTTPS GitLab instance; numeric User ID, username and any name/email actually exchanged must be included. | Collection candidate for account management and functionality; assess the selected instance's role rather than blanket-exempt BYO credentials. GitLab token is not intended model context. | `lib/core/gitlab_api.dart:293`, `:756`; `lib/core/oauth.dart:87`; `lib/features/auth/session_controller.dart:803`. |
| E. GitLab uploads | User-selected attachment bytes, filename and content type go as multipart to the specified GitLab project. Photos, Videos and Files and docs as supported by actual picked content. | Off-device collection candidate; user-initiated sharing exception requires review. App functionality. Synthetic MR7 test bytes are not the full product data-type inventory. | `lib/core/workspace_api.dart:602`; AI upload port `lib/core/ai/tools/write_coordinator.dart:2297`. |
| F. GitLab content / actions | Created or edited issue/MR/comment/file/snippet content, AI-reviewed generated text, project/resource IDs and requested operations go to the bound GitLab instance. Other user-generated content, Files and docs, Other in-app messages, User IDs as actually sent. | App functionality; manual features already exist with AI off. AI writes additionally require release capability and consent gates. A staged draft is local until an actual write; published content follows server visibility and retention. | `lib/core/workspace_api.dart`; `lib/core/ai/tools/write_coordinator.dart`; account identity contract in `AGENTS.md`. |
| G. AI safety report, conditional | Category, description, version, provider preset/protocol format/model/time/response index and optionally the selected redacted generated response. Other user-generated content/messages; Diagnostics only for actual report metadata. Recipient is the selected email/share destination; developer receipt is unproved. | Optional off-device handoff; safety/compliance and functional maintenance, not automatic crash telemetry. No private response included by default. Review sharing exception and actual recipient before claiming a collection route or retention policy. | `lib/core/ai/ai_report.dart:30`; `lib/features/ai/ai_chat_page.dart:510`; `lib/features/ai/ai_report_sender.dart:9`. |
| H. GitLab / external media reads | GitLab resource URLs/IDs and authenticated headers for instance-owned reads; credential-free requests for external HTTPS Markdown images/media and permitted redirect/download destinations. The destination sees normal network metadata, including the originating IP. | App functionality. No account token is intended for third-party media/CDN hops. Review each SDK/recipient and any logged identifiers; receiving an image does not by itself prove no outgoing request data. | GitLab client redirect guard; separate media client and HTTPS/address checks in `lib/shared/markdown_media_source.dart:512`, `:690`, `:899`; rendering in `lib/shared/markdown_media.dart:178`. |
| I. App updates | GitLab flavor: anonymous project release/metadata/APK requests. Play flavor: native Play in-app update calls. | App functionality. Anonymous requests still expose network metadata to their destinations. Play-services/platform data practices require their own submission-time review; do not copy GitLab updater claims into Play. | `lib/features/update/update_controller.dart:83`, `:141`; `lib/core/anonymous_api.dart:16`; generated flavor-specific `AppUpdateChannel`. |
| J. Explicit links / OS sharing | Canonical resource links, user-selected artifact/files or report text can be handed to the selected external app/browser. | User choice of destination is relevant to sharing exceptions, not proof that no transfer occurs. External app/recipient retention is unknown here; no authenticated GitLab headers are to be forwarded. | `lib/shared/resource_share.dart:84`; `lib/shared/external_link.dart:18`; share-provider manifest. |

### 3.3 Flow-level optionality, retention, deletion and encryption

| Flow | Can user avoid this flow? | Ephemeral / recipient retention and deletion | Transport answer |
|---|---|---|---|
| A / B | AI can remain disabled while using the GitLab client; attachments/context can be omitted. An enabled request's required payload fields are not independently optional. | **Unknown per actual provider/model/tier** until checked against §5; never inherit Custom or router retention from a preset. Local history clear does not delete remote data. | Hosted presets use HTTPS. Explicit private-IP LAN HTTP is permitted by endpoint policy when opted into; see §3.4. |
| C | Provider use is optional; keyed providers require their key to authenticate, while eligible local/keyless configurations differ. | Provider security logs and credential/account deletion are provider-specific; local key removal is not remote revocation. | Same endpoint transport as A; HTTP would also expose its authentication header. |
| D | A working signed-in GitLab session requires authentication/identity; AI opt-out does not remove that requirement. | GitLab/server-admin policy controls logs, account records and revocation. Local account removal removes local state only. | GitLab instance parser requires HTTPS; OAuth browser/provider legs still require exact integration verification. |
| E | User can decline picking/uploading. Do not mark Photos/Videos/Files optional globally until every other use of those types is checked. | Posted uploads persist under GitLab/server policy and resource deletion/access controls. Dropping memory or deleting picker copies does not delete the upload. | Selected GitLab instance uses HTTPS. Actual multipart/network/device proof **NOT_RUN** here. |
| F | Individual writes are optional; normal read/client use need not post. Identity may still be required under D. | Persisted on GitLab, not ephemeral; actual removal rights, backups and retention belong to that instance. | HTTPS source contract; actual server writes **NOT_RUN** in 7C. |
| G | User can cancel, omit response content, and choose whether to hand off the report. | No delivery/retention/erasure receipt exists. Mail/share client and recipient policies apply after handoff; developer processing is an open item. | `mailto` / share is not a transport-encryption guarantee; no report backend TLS claim is supported. |
| H | Media/link choices can be avoided where exposed; ordinary GitLab reads still need their resource requests. | Destination access logs/CDN policy unknown. A bounded transient download does not establish ephemeral server logging. | Existing external media requests require HTTPS; separate socket behavior is not a new all-flows proof. |
| I | Update checks have an app preference; user confirmation controls install/update. Verify all device/region cases before type-level optionality. | GitLab / Google Play logging governed by those services; no developer-operated updater backend identified. | GitLab source uses HTTPS; Play SDK transport/data review remains open. |
| J | User can cancel external opening/sharing. | External recipient/app controlled; not a local retention guarantee. | External destination-specific; do not assert universal encryption for arbitrary OS share targets. |

### 3.4 LAN HTTP and form scope

`lib/core/ai/ai_endpoint.dart:205` permits HTTP only when `allowLanCleartext`
is set and the host satisfies the private-IP/loopback checks (`:243`), including
private IPv4, loopback, link-local, IPv6 unique-local and configured carrier-grade
NAT ranges. Arbitrary public HTTP endpoints are rejected by that source policy.
A server on another LAN machine is **off-device**, even if it runs Ollama or
LM Studio. True loopback processing on the same device is a separate case.
Neither a local-model product name nor `usesCleartextTraffic=false` proves
that all actual networking is encrypted or blocked.

Do not tick all-data-encrypted Yes for an AI-enabled Play configuration that
can actually send content/keys to off-device HTTP. This packet did not modify
Play endpoint policy to obtain a different answer. A future HTTPS-only Play
restriction needs a lead-owned UX/implementation decision and real network
tests. These AI-off APKs have no AI-LAN execution evidence in either direction.

### 3.5 Local-only storage and OS display

| Store / display | Technical facts; no additional off-device transfer from storage alone |
|---|---|
| Secure credentials / drafts / settings | `flutter_secure_storage`; account- and recipient-scoped keys/bindings. Storage encryption is distinct from provider/server processing. App-lock biometric authentication uses OS APIs; no biometric template network flow identified. |
| Opt-in AI history | Off by default; redacted display history encrypted per account with AES-256-GCM, 512 KiB/conversation, 50 conversations, 16 MiB/account, 64 MiB/device, 7/30/90-day retention (default 30). Missing/unavailable keys do not authorize silent replacement/deletion. |
| AI write journal | Encrypted metadata only: operation, target identity, digest and state; no bodies, file bytes or provider replay. Up to 200 entries / seven days, with unresolved dispatch/uncertainty retained; counters up to 2,000 / 90 days. Not a provider conversation log. |
| Read cache | Encrypted allowlisted projections and confirmed versions; 32 MiB/account, 96 MiB/device, seven-day expiry. Source/diffs/logs may still contain secrets; encryption is not content redaction. |
| Offline snapshots | Separate encrypted `offline_repo/` keys and storage, explicit save consent, 150 MiB/snapshot, 600 MiB/account / 30 snapshots. Account/session cleanup and refusal rules are in `CLAUDE.md` Persistence. Do not apply C2's smaller cache cap to snapshots. |
| Attachments / temporary caches | AI-picked bytes held in memory, omitted from provider metadata, dropped/wiped under the attachment lifecycle. Picker/share/media/artifact copies have separate best-effort cleanup contracts; process-death cleanup is not proved here. |
| Notifications | Local OS display, generic public status/stop content. A declared notification permission does not mean content is uploaded. Runtime lock-screen/channel behavior is **NOT_RUN**. |
| Analytics / crashes | No Firebase Analytics/Crashlytics/Sentry application SDK identified in `pubspec.yaml`, lockfile and source search. GitLab project analytics APIs are a user-facing GitLab feature. Do not invent a telemetry flow or claim exhaustive runtime/SDK absence from grep alone. |

Retention, tombstones, cleanup ordering and platform limits are binding in
`AGENTS.md` and `CLAUDE.md` Persistence (`:89` onward). Account removal is not
guaranteed to succeed if secure-storage/file cleanup fails. iOS local protection
and backup limits remain independently untested; Android artifact flags do not
prove native backup/restore behavior.

Official form guidance, accessed 2026-10-29:
[Play Data safety](https://support.google.com/googleplay/android-developer/answer/10787469?hl=en).
Privacy-policy content must enumerate recipients, conditional AI/context and
metadata, LAN transport, deletion limits and report handling; provide an actual
public URL, current contact and retained policy version before submission.
`docs/STORE_LISTING.md`'s local-cache statement alone does not cover AI flows.
Public policy/contact/deletion URL validation remains **NOT_RUN**; **lead to phrase**.

## 4. Generative-AI policy and existing report flow

Treat the AI policy as applicable to the conversational/agent feature until
the lead has a documented scope decision. Productivity category and narrow
productivity-assistance examples do not establish this app's exemption. The
official general policy page currently states an effective date of
2026-09-30 unless separately noted; this does not date the first appearance of
the AI reporting requirement. Sources accessed 2026-10-29:
[general policy](https://support.google.com/googleplay/android-developer/answer/18258653?hl=en),
[AI content policy](https://support.google.com/googleplay/android-developer/answer/13985936?hl=en),
[scope guidance](https://support.google.com/googleplay/android-developer/answer/14094294?hl=en).

| Policy / implementation field | Existing evidence | Disposition / owner |
|---|---|---|
| Prevent restricted generated content, including child exploitation and deceptive behavior | BYO providers, redaction and tool authorization are not proof of complete generated-content moderation. No prohibited-content live generation was attempted. | Safe synthetic refusal/filtering tests and recipient/model policy review required. **NOT_VERIFIED**; lead/7D. |
| Report entry and user choice | `ai_chat_page.dart:510` presents a rebuilt/redacted preview and refreshes live-secret masking; generated response is optional. `ai_report.dart:30` constructs bounded category/description/build/provider/model/time metadata. | Useful source support; real UI/device behavior and all-locale meaning **NOT_RUN**; lead/7D owns wording. |
| Report without exiting the app | `ai_report_sender.dart:9` launches `mailto`, falls back to `share_plus`, and uses an external application. `ai_chat_page.dart:590` can mark reported after a handoff opens. | **NOT_VERIFIED / reporting compliance gap.** Handoff is not submission to a developer within the app. No in-app backend, delivery acknowledgment or receipt proved. |
| Feed reports into improvement/moderation | No actual developer receipt, triage/retention process, response commitment or moderation feedback evidence collected. | Lead chooses lawful recipient/process; 7D implements reviewable consent/status/receipt UX. Do not describe a report as received merely because a share sheet opened. |
| Safe reviewer access | No reviewer credentials or private project/provider key supplied. | Lead to prepare synthetic fixtures, safe account access/steps and cost limits; no private material in the handoff. **NOT_RUN**. |
| Enablement | Both flags false for these artifacts; background manifest still present. | **Play AI remains off (7-D10)** until declarations, content/reporting, artifact and relevant device evidence are complete. No policy approval claimed. |

## 5. Every preset: official terms and data-use references

All 12 entries in `AiPresets.all` (`lib/core/ai/ai_provider.dart:818`)
are accounted for below. Official pages were accessed on **2026-10-29
Asia/Taipei**; this is independent of the source's historical
`policyCheckedOn='2026-10-20'`. Access confirms what a page states, not the
user's contract, subscription, region, selected model or actual processing.
Final per-recipient disclosure and consent wording: **lead to phrase**.

| Preset | Official terms / data-use URLs (accessed 2026-10-29) | Limits to record before submission |
|---|---|---|
| OpenAI | [Services agreement](https://openai.com/policies/services-agreement/); [API data controls](https://developers.openai.com/api/docs/guides/your-data) | API training is off by default; ordinary abuse logs can retain up to 30 days. Responses/stateful features have additional retention behavior. ZDR depends on eligibility/configuration; no blanket zero retention. |
| OpenRouter | [Terms](https://openrouter.ai/terms); [privacy](https://openrouter.ai/privacy); [provider practices](https://openrouter.ai/providers/) | Route, downstream provider/model and account settings determine training/retention. Verify both router and downstream recipient; do not treat all models identically. |
| Azure OpenAI | [Microsoft product terms](https://www.microsoft.com/licensing/terms/en-US/product/MicrosoftAzure/all); [data privacy](https://learn.microsoft.com/en-us/legal/cognitive-services/openai/data-privacy) | No foundation-model training without permission/instruction under the documented service. Deployment geography/type, abuse monitoring and stateful features affect processing. Exact subscription/deployment and retention **to verify at submission**. |
| Gemini | [API terms/data use](https://ai.google.dev/gemini-api/terms); [tiers](https://ai.google.dev/gemini-api/docs/pricing) | Unpaid use may support improvement/human review; paid and EEA/UK/Swiss provisions differ, with safety logging. Verify selected tier/model and contributor conditions; no universal no-training claim. |
| DeepSeek | [Open Platform API terms](https://cdn.deepseek.com/policies/en-US/deepseek-open-platform-terms-of-service.html); [privacy](https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html) | Terms/privacy pages fetched, but exact API applicability, training, retention and region remain **to verify at submission**. The older platform user-agreement PDF returned 403; an older privacy PDF does not establish the current API agreement. |
| xAI | [Enterprise/API terms](https://x.ai/legal/terms-of-service-enterprise); [privacy](https://x.ai/legal/privacy-policy); [enterprise FAQ](https://x.ai/legal/faq-enterprise) | Terms updated 2026-10-27; training/settings and normally up-to-30-day retention have exceptions. ZDR election/configuration must be checked; the FAQ is older than the terms. |
| Ollama | [Terms](https://ollama.com/terms); [privacy](https://ollama.com/privacy) | Local inference, Ollama cloud inference and a user-run remote server are different recipients. Local processing on the server does not mean on the phone. Third-party server retention **unknown**. |
| LM Studio | [Desktop terms](https://lmstudio.ai/app-terms); [desktop privacy](https://lmstudio.ai/app-privacy) | Local host inference differs from separately selected cloud features and remote-server logging. User/server settings and the actual host's policy **to verify at submission**. |
| Anthropic | [Commercial terms](https://www.anthropic.com/legal/commercial-terms); [commercial data use](https://privacy.anthropic.com/en/articles/7996868-is-my-data-used-for-model-training); [retention](https://privacy.anthropic.com/en/articles/7996866-how-long-do-you-store-my-organization-s-data) | API retention is generally up to 30 days, with agreement/safety/legal exceptions. Training opt-in/feedback exceptions and any ZDR arrangement need actual account confirmation. |
| OpenCode Go | [Terms](https://opencode.ai/legal/terms-of-service); [privacy](https://opencode.ai/legal/privacy-policy); [Go model table](https://opencode.ai/docs/go/) | Model-specific training/retention differ. The documented DeepSeek ZDR arrangement runs only through 2026-10-31 with renewal conditions: **recheck at submission**. Historical preset values are not current-policy proof. |
| OpenCode Zen | [Terms](https://opencode.ai/legal/terms-of-service); [privacy](https://opencode.ai/legal/privacy-policy); [Zen information](https://dev.opencode.ai/zen) | Described no-training/zero-retention baseline has exceptions, including relevant unpaid/third-party routes. Verify actual model/account and hosting region; do not copy Go's model table onto Zen. |
| Custom | No universal official terms/data-use URL. | Endpoint operator, agreement, downstream recipients, training, retention and region **unknown / to verify at submission**. No preset privacy promise can be inherited. |

A provider page's successful fetch is not a live provider request, consent
roundtrip, policy-version migration, cross-region test or proof of legal terms
applicability. Those row-11 subgates remain open. No provider setting, preset,
key or model-policy source was modified by 7C.

## 6. Acceptance commands and evidence

The session evidence directory is `../../evidence/` relative to this document
(outside `repo/`). Required-command logs and adjacent JSON receipts include
exact argv, start/end UTC, exit code and last nonempty line. Additional XML
decode receipts include exact argv, exit code and last line; their enclosing
survey receipt supplies start/end UTC. Build intermediates
were directed there through a temporary local build link. The four APKs,
same-build mappings, merged manifests and merger reports were copied and
SHA-256 verified before removing that link and this session's build tree.
Raw receipts retain their original build paths; `packaging-receipt.json`
maps those paths to the retained files. No private signing material is included.

All commands below ran from `repo/`. `run_command.py` records subprocess
exit codes without treating a wrapper success as the tested result. Python
commands inherited `PYTHONDONTWRITEBYTECODE=1`.

| Command / receipt label | Exit | Last nonempty output line |
|---|---:|---|
| `fvm flutter pub get --enforce-lockfile`; `pub-get.json` | 0 | ``Try `flutter pub outdated` for more information.`` |
| `fvm flutter build apk --debug --flavor gitlab --target lib/main.dart` + both false defines; `gitlab-debug-build.json` | 0 | `✓ Built build/app/outputs/flutter-apk/app-gitlab-debug.apk` |
| Same debug command with `--flavor play`; `play-debug-build.json` | 0 | `✓ Built build/app/outputs/flutter-apk/app-play-debug.apk` |
| `python3 tool/mr6c_artifacts.py build-release` with exact source/lock, captured per-flavor commands in JSON; `release-builds-command.json` | 0 | `}` |
| `python3 -m unittest discover -s tool/tests -p test_bootstrap.py` (initial: 68 tests, one conditional skip); `bootstrap-tests.json` | 0 | `OK (skipped=1)` |
| Same suite with `-v` and `MR6C_GENERATED_ROOT=$PWD` after both debug builds: 68 tests, no skips; `bootstrap-tests-actual.json` | 0 | `OK` |
| `python3 -m unittest discover -s tool/tests -p test_ai_boundaries.py -v`: 40 tests; `ai-boundaries-tests.json` | 0 | `OK` |
| `python3 ../evidence/artifact_survey.py`: packaged XML and scoped literal observations; `artifact-survey-command.json` | 0 | `Artifact survey complete: 4 manifests, 8 packaged XML rules, and scoped QA literal scans.` |
| `python3 tool/mr6c_artifacts.py readback` with both captured R8 receipts; explicit remaining AOT gap; `c8-artifact-readback.json` | 1 | `}` |

The release builder invoked, sequentially for `gitlab` and `play`:
`fvm flutter --verbose build apk --no-android-gradle-daemon --release --flavor <flavor>`.
Each underlying build exited **0**, with last line
`[        ] exiting with code 0`; each also printed its own successful
`Built build/app/outputs/flutter-apk/app-<flavor>-release.apk` line.
Lock hashes before and after each build match §1.

Mandatory raw readback commands were run separately on **each** APK:
`apkanalyzer manifest print <APK>`, `aapt2 dump permissions <APK>`,
`apksigner verify --verbose --print-certs <APK>`, `shasum -a 256 <APK>`.
The exact SDK executable and APK paths are in the individual JSON receipts.

| Artifact / command receipt | Exit | Last nonempty output line |
|---|---:|---|
| `gitlab-debug-manifest.json` | 0 | `</manifest>` |
| `gitlab-debug-permissions.json` | 0 | `uses-permission: name='io.gitlabmobile.gitlab_mobile.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION'` |
| `gitlab-debug-signer.json` | 0 | `Signer #1 public key MD5 digest: 6ceb503a194322cfe60356ef596f29e4` |
| `gitlab-debug-sha256.json` | 0 | `77a6283c601d31ff412727c74c92e7e7d1bc6ee58e99d06e12388ecc33f8ed90  ../evidence/build/app/outputs/flutter-apk/app-gitlab-debug.apk` |
| `play-debug-manifest.json` | 0 | `</manifest>` |
| `play-debug-permissions.json` | 0 | `uses-permission: name='app.mergeline.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION'` |
| `play-debug-signer.json` | 0 | `Signer #1 public key MD5 digest: 6ceb503a194322cfe60356ef596f29e4` |
| `play-debug-sha256.json` | 0 | `1b0ae07c083a6918b227832027eddb4797704eae98143f89aacf6371174f5b84  ../evidence/build/app/outputs/flutter-apk/app-play-debug.apk` |
| `gitlab-release-manifest.json` | 0 | `</manifest>` |
| `gitlab-release-permissions.json` | 0 | `uses-permission: name='io.gitlabmobile.gitlab_mobile.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION'` |
| `gitlab-release-signer.json` | 0 | `Signer #1 public key MD5 digest: 6ceb503a194322cfe60356ef596f29e4` |
| `gitlab-release-sha256.json` | 0 | `0f1dcfa3e880f26b3184c313755f32f4a4cbc77cdcf801f0dca8d113c7a21149  ../evidence/build/app/outputs/flutter-apk/app-gitlab-release.apk` |
| `play-release-manifest.json` | 0 | `</manifest>` |
| `play-release-permissions.json` | 0 | `uses-permission: name='app.mergeline.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION'` |
| `play-release-signer.json` | 0 | `Signer #1 public key MD5 digest: 6ceb503a194322cfe60356ef596f29e4` |
| `play-release-sha256.json` | 0 | `e66b66d9997d405837638369d9ed5c5c0ca4946ca001c8850fd16f76172aff2b  ../evidence/build/app/outputs/flutter-apk/app-play-release.apk` |

`aapt2 dump badging` also exited 0 on each APK. Packaged backup XML
was resolved by resource ID/path and decoded from all four APKs:
legacy backup, cloud backup and device-transfer rules exclude `root`,
`file`, `database`, `sharedpref` and `external`, each at path `.`;
`cloud-backup` has `disableIfNoEncryptionCapabilities=true`. All eight
XML decode commands exited 0; their `*-backup_rules.json` last lines are
`</full-backup-content>` and `*-data_extraction_rules.json` last lines
are `</data-extraction-rules>`. This establishes configuration, not
an actual backup/restore run. Final `git diff --check` and the untracked
document whitespace check are recorded in `RESULT.md` after completion.

## 7. Remaining gates and ownership

| Coverage / gate | This packet's evidence | Still open |
|---|---|---|
| §9 row 11: recipient/consent/version | Every preset mapped to official references; source consent boundary identified. | Actual configured recipient/tier/model and renewed-consent live/device evidence; unknown policy applicability retained. |
| Row 15: outward consistency | Technical statements explicitly identify provider metadata, remote retention, local cleanup and LAN limits. | Lead/7D store/privacy copy, 24-locale semantic and device review; history format roundtrip belongs to 7R. |
| Row 22: native/flavor/SDK/signing | Fresh debug and available local release APK receipts/readback. | Play AAB and upload/app-signing identity, production distribution and device acceptance. |
| Row 23: attachments | Metadata/bytes split documented; no broad picker permissions added. | Actual picker/process-death cleanup, multipart/provider counters and live upload/provenance roundtrip. |
| Rows 27/28: background/native/resume | Service/type/export/permission receipt and source flags; no AI/background enablement. | C8 V1–V12 OS cases, notification denial/channel/stop/timeout, engine/ticket/death/resume and no-duplicate billing/dispatch proof; iOS separate. |
| C8 R8 / optimized Dart QA isolation | Native artifact results are scoped in §1.3. | Full optimized Dart AOT handler/channel absence remains **NOT_VERIFIED**, not replaced by grep. |
| FGS / AI / privacy | Technical field drafts, source mapping and freshly accessed references. | Real demo video, lawful in-app report receipt/triage, public privacy/deletion/contact URLs, reviewer access and final lead wording. |

**NOT_RUN in 7C:** Play Console access/forms/submission/review/approval;
uploads, Play AAB, Play App Signing and store publication; new signing keys;
real provider requests or billing; real GitLab writes/uploads; emulator and
physical-device checks, C8 V1–V12, backup/restore and HTTP socket enforcement;
iOS build/native roundtrip/device/TestFlight; full 7R release CI/test/live
acceptance and locale/store-copy review. No G0/MR7/Play acceptance is inferred
from this document or local packaging.
