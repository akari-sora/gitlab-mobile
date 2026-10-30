# CI and development preview delivery

## Workflow

The repository uses project-locked private runners on the two-host CI fleet, with tags `grok-box`, `ondemand`, and `gitlab-mobile`. Each host executes at most one CI job at a time; its dispatcher rotates between projects with eligible pending jobs after each job finishes. Jobs can therefore wait for a fleet turn, but do not consume GitLab-hosted runner compute quota. Pushes, merge-request events, tags and manually started branch pipelines run checks; a merge request that changes only documentation skips the Flutter, native and Android jobs (see [Docs-only merge requests](#docs-only-merge-requests)). A branch push with an open MR is suppressed to avoid duplicate branch/MR pipelines. A new commit cancels the superseded pipeline of the same ref. On `main` the cancel is conservative: a pipeline still waiting for a runner is cancelled, but once its non-interruptible `main_run_to_completion` job has started it runs to the end, so `main` is still verified (and its preview published) when pushes arrive faster than a pipeline finishes. All required jobs use `allow_failure: false` by default.

New projects require explicit runner registration and dispatcher onboarding on each host; adding tags alone does not grant access. For this project, both registrations are locked to `gitlab-mobile` and reject untagged jobs. The existing `python:3.13-slim` job image, toolchain pins, checks and artifact delivery remain in use. A pipeline created before the routing change retains its old job tags; verify a new pipeline for the updated commit rather than retrying the old quota-failed jobs.

1. `python_checks`: report-converter, local-smoke runner, package-installer and native-bootstrap regressions, Python compilation, shell syntax.
2. `flutter_checks`: dependency-lock enforcement, Flutter analysis, 68 Flutter unit/widget/smoke tests in the initial CI baseline, JUnit and LCOV. It runs every test file except the MR7 sandbox tool tests (see [Test lanes](#test-lanes)). The current test count is read from the job report, not inferred from this document.
3. `flutter_ai_checks`: the same analysis and the complete test suite, including the MR7 sandbox tool tests; tests run with `MERGELINE_AI_ASSISTANT=true` and `MERGELINE_AI_BACKGROUND=false`. It inherits the same rules, runner tags and retry policy as `flutter_checks`, with separate `ci-output-ai/` and `coverage-ai/` artifacts. Both check jobs have a 40-minute timeout; each test process has a 30-minute deadline and 15-second TERM-to-KILL grace period (see [Timeouts](#timeouts)). The limits were 25 and 22 minutes until 2026-10-30, when the suite took 24–25 minutes on the shared 9700X host under load and every Flutter job hit the job limit; `python_checks` and `main_run_to_completion` went from 5 to 10 minutes for the same reason.
4. `native_templates`: generate/review Android and iOS runner configuration from the pinned SDK. Linux generation is not an iOS build or device test.
5. `android_debug`: needs the Python checks, both Flutter checks and native templates, reuses the default check's dependency lock and native templates, and builds the `gitlab`-flavor Android APK: a release build on protected refs (`main`, `v*` tags), a debug build everywhere else (the job keeps its historical name).
6. `publish_preview`: automatic delivery (AI on since v0.6.0, `deliver_preview.sh owner`) on this project's protected `main` branch for every non-MR source admitted by the workflow, including `trigger` and `pipeline`; special smoke/sync pipelines are excluded. Runtime verification preserves that source policy and the project/job/protected-main identity checks. It verifies checksums and uploads APK/metadata/checksums to the same project's Generic Package Registry.
7. `mr7_release_attestation` and `publish_preview_ai`: separate manual jobs for this project's protected `main` branch and the `mr7-release` environment, created only for `push`, `web`, `api` and `schedule` sources, excluding special pipelines. Runtime verification accepts the same strict source set. AI-on delivery requires the external attestation described below.

`public_api_smoke` is not part of push, merge-request or tag pipelines; see [Public API smoke](#public-api-smoke).

`test/visual_evidence_test.dart` loads `/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc` when `GITLAB_MOBILE_TEST_FONT` is unset. That Linux path stays the CI default. On a Mac, keep `CI=true` and point the variable at an existing system font so the required CJK glyph checks still run. The path contains a space, so quote the assignment:

```sh
CI=true GITLAB_MOBILE_TEST_FONT='/System/Library/Fonts/STHeiti Medium.ttc' \
  fvm flutter test --no-pub --timeout=60s test/visual_evidence_test.dart
```

A missing chosen font still fails that required CI check. The test does not install a font or fall back to a Mac path on its own.

`test/work_item_assignee_api_test.dart`, `test/work_item_assignee_ui_test.dart` and `test/emulator_work_item_assignees_fixture_test.dart` cover project/group assignee replacement. The current isolated run is 50 passed (20 API, 20 UI, 10 fixture), with zero failures, errors and skips, plus scoped analysis of those files. An earlier fixture log passed 39 cases that also include weight and milestone; that is a separate run. API and fixture review approved with zero must-fix items. UI final review is APPROVE with zero required changes (`artifacts/mobile-parity/work-item-assignees/ui-final-review.json`: 50 passed, 20 API / 20 UI / 10 fixture, zero failures, errors and skips). Full suite, archive, new commit, APK, native, private, iOS and G0 checks for assignees are **NOT_RUN**. Run these with the enforced lockfile and `--no-pub` after that resolve. Do not skip the CJK font check and do not treat the targeted run as an APK. [Pipeline 2909579097](https://gitlab.com/aa22396584/gitlab-mobile/-/pipelines/2909579097) was observed running on the previous HEAD. This assignee source has no new commit, so that pipeline is not its result.

No tests or analyzer failures are ignored. A missing/unsuccessful Flutter completion event makes the JUnit conversion fail. Tests emit compact live progress, per-test limits and an overall test-process deadline. CI does not silently fix or reformat the source and claim the changed code was tested.

## Docs-only merge requests

The runner `r9700x-docker` is shared with another project. On 2026-10-29, with 8–9 merge requests open, 61 jobs were queued, and a merge request that changed only `docs/PLAN_STATUS.md` (!245) still ran `flutter_checks` and `flutter_ai_checks`, each the whole Flutter suite (about 21–25 minutes).

`flutter_checks`, `flutter_ai_checks`, `native_templates` and `android_debug` therefore extend `.app_regular` instead of `.regular`. In a merge-request pipeline they are added only when at least one changed file is neither a Markdown or image file under `docs/` nor a Markdown file in the repository root:

```yaml
- if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
  changes:
    regexp: '\A(?!docs/.*\.(?:md|png|jpg|jpeg|gif|svg|webp)\z)(?![^/]*\.md\z)'
- if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
  when: never
```

- **Docs-only** means every changed file is a `*.md`, `*.png`, `*.jpg`, `*.jpeg`, `*.gif`, `*.svg` or `*.webp` file under `docs/` (lower-case extensions), or a root `*.md` file (`README.md`, `AGENTS.md`, `CLAUDE.md` and so on). Any other file runs all four jobs: `lib/`, `test/`, `tool/`, `ci/`, `integration_test/`, `android/`, `ios/`, `assets/`, `pubspec.*`, `.gitlab-ci.yml`, `analysis_options.yaml`, `.fvmrc`, a Markdown file below the root such as `lib/README.md`, a new top-level file or directory, and every other file under `docs/`. The pattern names what is documentation rather than what is code, so a path nobody listed runs the jobs.
- Only those file types count because `flutter analyze` reads the whole package, and `analysis_options.yaml` does not exclude `docs/`: a `docs/**/*.dart`, `docs/**/pubspec.yaml` or `docs/**/analysis_options.yaml` file is analysed, and a broken one would turn `main` red after a merge request that skipped the analyzer. JSON, YAML, text and other non-Markdown files under `docs/`, such as `docs/ANDROID_RELEASE_INVENTORY.json` and the JSON receipts in `docs/receipts/`, therefore run the full jobs.
- A renamed or moved file counts with both paths. Without `compare_to`, a merge-request pipeline takes the merge request's changed paths, where a rename is the old path deleted and the new path added, so moving `lib/x.dart` to `docs/x.md` (or a root file to `X.md`) runs the jobs because of the old path.
- A merge request with no changed files skips the four jobs. So does one whose changed paths GitLab cannot work out (for example after a Gitaly error): `rules:changes` then sees an empty list and does not match. The pipeline still has `python_checks`, and `main` runs everything after the merge.
- `python_checks` keeps running, so the pipeline is never empty. It carries the checks that read documentation, translations and boundaries: `tool/tests/test_l10n.py`, `test_ai_boundaries.py`, `test_offline_boundaries.py` and `test_ai_runner_contract.py` (which reads `docs/V0_6_AI_VERIFICATION.md`), plus the pipeline tests in `ci/tests/`. No Flutter test reads a file under `docs/`.
- **Main, tag, schedule, API, web and plain branch pipelines run everything.** The `changes` rule applies only when `CI_PIPELINE_SOURCE` is `merge_request_event`; the publishing and attestation jobs, which need `android_debug`, run only on `main`.
- The four jobs share one rule set, so `android_debug` and the jobs it needs are always added or skipped together. The needs are deliberately not [`optional`](https://docs.gitlab.com/ci/yaml/#needsoptional): a missing needed job stays a pipeline error instead of a silently skipped dependency.
- Special pipelines (`LIVE_SMOKE`, `RESOLVE_LOCK`, `PUBLIC_SMOKE`, `GH2GL_SYNC`) skip the four jobs as before.

GitLab details, from [`rules:changes`](https://docs.gitlab.com/ci/yaml/#ruleschanges), [`rules:changes:compare_to`](https://docs.gitlab.com/ci/yaml/#ruleschangescompare_to) and [`rules:changes:regexp`](https://docs.gitlab.com/ci/yaml/#ruleschangesregexp):

- `regexp` needs GitLab 19.2 or later, and gitlab.com accepts it. It is a Ruby regular expression, matched against each changed path; the rule holds when any path matches. It is anchored with `\A` and `\z` because a Git path can contain a newline; `.` does not match a newline, so a path under `docs/` with a newline in its name runs the jobs. Glob `paths` have no exclusion, so they would have to list every code path, and a forgotten one would skip the jobs.
- In a merge-request pipeline, changes are compared with the merge request's target branch. The rule deliberately has no `compare_to`: with it, GitLab reads the changed paths from diff statistics with rename detection on and keeps only the new path of a renamed file, so `git mv lib/x.dart docs/x.md` would look docs-only.
- When more than 50,000 files changed, GitLab treats the rule as matched and runs the jobs.

`DocsOnlyMergeRequestTests` in `ci/tests/ci_pipeline_config_test.py` models these rules for every pipeline source, checks that every needed job is present, checks renames and that the rule has no `compare_to`, and checks the pattern against the docs-only definition for every tracked file.

## Test lanes

`flutter_checks` (AI gate off) and `flutter_ai_checks` (gate on) each ran every test file. The MR7 sandbox tool tests, `test/ai/mr7_sandbox_*_test.dart` (several hundred tests added on 2026-10-29), exercise the host sandbox runner in `tool/mr7/` rather than the app's AI gate, so running them in both lanes only doubled their time. Under that load two check jobs hit what was then a 25-minute job timeout, and several tests the 60-second per-test timeout (issue #52).

`ci/check.sh` now passes `flutter test` an explicit, sorted list of every `*_test.dart` file under `test/`, which is what `flutter test` finds on its own. That includes a `*_test.dart` symlink that leads to a file; like `flutter test`, the listing does not follow links into directories and drops a dangling link.

- the default lane (`ci/check.sh`, gate off) leaves out `test/ai/mr7_sandbox_*_test.dart` and any `test/ai/mr7_live_*_test.dart` directly in `test/ai/`;
- the `ai` lane (`ci/check.sh ai`, gate on) runs every file;
- the gate tests `test/ai/mr7_release_gate_test.dart` and `test/ai/mr7_background_gate_test.dart` run in both lanes, because they test the gate itself.

No test file is edited. Coverage and the JUnit report work as before, and each lane's test count still comes from its JUnit report. The default lane's coverage no longer includes code that only the sandbox tool tests reach; `flutter_ai_checks` still reports it. The job log shows the selection (`ci/check.sh: default lane runs N of M test files`). To see a lane's files without Flutter:

```sh
bash ci/check.sh default --list-tests   # one path per line; the count goes to stderr
bash ci/check.sh ai --list-tests
```

The script stops before Flutter when it finds no test file, because `flutter test` without file arguments would run the whole `test/` directory. `CheckScriptTests` in `ci/tests/ci_pipeline_config_test.py` checks both lanes on a synthetic tree (with symlinked test files) and on this repository's `test/`.

## Timeouts

`ci/check.sh` stops the test process after 30 minutes (`timeout --signal=TERM --kill-after=15s 30m flutter test`), and `flutter_checks` and `flutter_ai_checks` have `timeout: 40m`. The 10 minutes between them cover the rest of the job, so the inner limit always fires first and the reports survive: before the tests, the Flutter SDK setup, the source checkout, `pub get` and `flutter analyze` took 1.5–6.5 minutes on the loaded runner (353.5 s in !247 job 17568286306, 392.9 s in !251 job 17571878548); after them come the JUnit report, coverage, the screenshot evidence, the cache archive and the artifact upload.

The limits were 22 and 25 minutes, and a first raise to 30 and 35 still let the job limit fire before the test limit under load. On the shared runner `r9700x-docker`, with both lanes running in parallel next to the other project's jobs, the whole-suite jobs finished at 24–25 minutes and kept hitting the job timeout on 2026-10-29: !247 `flutter_checks` at 1527 s (terminated mid-suite), !251 both lanes at 1531 s and 1526 s, and !245 `flutter_ai_checks` at 1510 s, killed in the post-test steps after analysis, tests and report had all exited 0. The higher limits are a stopgap next to the cuts in duplicated work above (docs-only merge requests and the MR7 sandbox tool tests in one lane), not a replacement for them. `native_templates`, `android_debug` and the delivery jobs keep their timeouts. `CiPipelineConfigTests` and `CheckScriptTests` in `ci/tests/ci_pipeline_config_test.py` pin both values.

## Toolchains and reproducibility

- Flutter 3.47.2 from its exact Git source tag; `flutter --version --machine` is checked before use.
- `pubspec.lock` versions and hosted-package SHA-256 values are committed. Both analysis and Android jobs use `flutter pub get --enforce-lockfile`.
- Android command-line tools build 15859902; the official Linux archive SHA-256 is pinned in `ci/install_android.sh`.
- The compile SDK is read from the pinned Flutter Gradle extension. The first build may install additional plugin-required platforms/NDK versions through the accepted Android SDK licenses.
- JDK 21, Python 3.13 and a Debian-based container. The container/OS patch packages and downloaded Android platform revisions are not fully byte-for-byte hermetic. Build metadata identifies the actual Flutter/Dart revision and source commit; do not claim bit-reproducible APKs.

Caches accelerate Flutter, Pub and Android/Gradle downloads. Only infrastructure failures are retried automatically. No unrelated VPS or project runner is enabled or reconfigured.

Package setup uses Debian HTTPS sources, three download retries and 30-second connection timeouts. An incomplete package-index update or failed installation stops the job immediately; signature and TLS checks remain enabled. This avoids the HTTP mirror 502 failure observed during private-runner onboarding, which previously left `git` unavailable for SDK installation.

Flutter jobs append `--no-same-owner` to `TAR_OPTIONS`, keeping extracted SDK files owned by the container's current user. Flutter's Gradle wrapper archive contains ownership IDs outside the rootless user mapping; restoring those archive IDs would fail. Jobs continue to run through the unprivileged container executor.

## Artifacts and credentials

JUnit, raw test JSON, analyzer output and LCOV remain attached to the check job even after failure where available. Android APKs, `SHA256SUMS` and `build-metadata.json` are retained as job artifacts for 14 days. Default-branch delivery creates a registry version named after the full commit SHA, not a mutable `latest` label.

Registry delivery uses `CI_JOB_TOKEN`. The AI-on attestation and delivery jobs additionally require a protected, `mr7-release`-scoped `read_api` file token, supplied as `MR7_GITLAB_READ_TOKEN_FILE`; `CI_JOB_TOKEN` alone cannot read the single-job API. This variable was not configured by this change. No credentials are committed, printed deliberately, embedded into the APK or sent in URL query strings. CI fixtures contain only synthetic API identities. The pipeline does not enable CI job-token repository pushes.

### MR7 release flags and attestation

`ci/build_android.sh` accepts explicit `--ai-assistant` and `--ai-background` boolean values and records the effective flags in `build-metadata.json`; absent flags are false. Since v0.6.0 (owner decision, 2026-10-30) CI passes `--ai-assistant true --ai-background false`, and `publish_preview` runs `deliver_preview.sh owner`: the AI-mode release-metadata checks (release build, package, stable certificate, flags, source digests, APK digest) without the 7R attestation or a second APK inspection (`android_debug` already inspected the APK it built). `MR7_RELEASE_AI` defaults to `false` and only routes delivery jobs: setting it does not change the compiled flags. The attestation lane below stays for a future 7R. The Play flavor rejects AI-on flags and stays off.

The manual attestation job takes numeric `MR7_RECEIPTS_JOB_ID` for a successful `mr7_release_receipts` job on protected `main` at the exact release SHA. Its `mr7-receipts/index.json` identifies the five required regular check jobs and each receipt's job ID, job URL, fixed path and SHA-256. The required receipt files are `mr7-receipts/live/{public_api_smoke,provider_smoke,production_operations,events_isolation}.json` and `mr7-receipts/emulator/production_smoke.json`. Each receipt must say `schema: 1`, `status: PASS`, its kind/name, release SHA, source digests, production policy, GitLab release flavor, AI-on/background-off flags and timezone-aware creation time. Receipts and attestation must be no more than 24 hours old. The receipt job and real live/emulator evidence are future 7R work: **NOT_RUN** here.

`RELEASE_REQUIREMENTS` in `ci/mr7_attestation.py` remains pending. 7R must commit the capability digest, complete operation/target/variant list and emulator rows; every required detail needs its own hashed receipt with independent readback/isolation or device result. Aggregate PASS receipts cannot authorize delivery. This commit cannot produce an eligible AI-on attestation. Both delivery modes authenticate their actual job with `CI_JOB_TOKEN` and verify current branch protection through GitLab; overridden predefined variables do not provide identity. AI jobs independently inspect the APK using pinned Android tools and reject tracked source changes.

AI-on delivery accepts a numeric `MR7_ATTESTATION_JOB_ID`, not an arbitrary attestation path or URL. It authenticates the current job, checks the attestation job's project, success, protected ref and pipeline SHA, then downloads the fixed job artifact and checks its bytes against `SHA256SUMS` and the successful job trace's digest. The provider ID must match that selected artifact job. The validator also checks the exact source, required checks and receipt digests, APK and metadata hashes, flavor, release build, package and stable CI certificate. Missing, stale or mismatched evidence stops delivery. The [Jobs API](https://docs.gitlab.com/api/jobs/) does not document an independent immutable artifact SHA-256 or historical ref protection; these properties, trace/artifact binding and token permissions require real protected pipeline evidence. No pipeline, variable, tag or release was created by this change.

## Public API smoke

`tool/public_smoke.dart` reads public gitlab.com projects anonymously through the production `GitLabApi`, with zero writes. Its result is *public live read* evidence, separate from the synthetic Flutter tests.

gitlab.com limits unauthenticated API traffic per IP address (`RateLimit-Name: unauthenticated_traffic_per_ip`). Every job on a self-hosted runner host shares that host's address, so the limit is shared too. One run fits in the budget; repeated runs do not. Until 2026-10-12, six runs within one hour passed on `r9700x-docker`. From 2026-10-17 the fourth run within an hour failed with HTTP 429, and the next run failed after a few checks. Once one request gets a 429, the client fails the rest fast with `rateLimited`. Checks that depend on an earlier result then fail their assertions with `FormatException`. These failures say nothing about the change under test.

So the job runs only in a pipeline with `PUBLIC_SMOKE=1` started by the API, a pipeline schedule, or **Run pipeline** in the web UI. All other jobs are skipped in that pipeline. No push, merge-request or tag pipeline runs it, and `android_debug` does not wait for it. A daily schedule on `main` runs it; GitLab notifies the schedule owner when that pipeline fails.

To start a run by hand, use **Build › Pipelines › Run pipeline** on the branch with variable `PUBLIC_SMOKE=1`, or the API:

```sh
curl --request POST --header "PRIVATE-TOKEN: <token>" \
  "https://gitlab.com/api/v4/projects/86648389/pipeline?ref=main&variables[][key]=PUBLIC_SMOKE&variables[][value]=1"
```

Before you tag a release, run it once on the release commit. In the release notes, link that pipeline or report the suite as `NOT_RUN`. A green push or merge-request pipeline does not include this evidence. A 429 is a rate-limit result, not a pass. Wait until the budget recovers and then start one new run. Do not retry the job repeatedly.

## Android signing lanes

Local Android debug, profile and release APKs use the same self-managed stable
development signer. Its canonical configuration and commands are documented in
[Android local signing](ANDROID_SIGNING.md). This gives local APKs a compatible
signer across build modes and worktrees; it does not make them Play or
production releases.

The preview records the commit in the app's 我的 tab. When
`ANDROID_DEBUG_KEYSTORE_B64` is set (protected refs only, see below),
`ci/build_android.sh` converts that keystore to a temporary PKCS12 identity
under the ignored `.ci-signing/` directory and builds a **release** APK
(`gitlab-mobile-<sha>-release.apk`, mode `stable-legacy-release`, refused unless
`CI_COMMIT_REF_PROTECTED=true`). Without it, the explicit CI fallback creates a
temporary PKCS12 identity restricted to the debug build type and builds a
**debug** APK (`-debug.apk`); that key is discarded with the job. Both record
the choice in `build-metadata.json` (`signing`, `build_type`).

Since 2026-10-18 the variable is set as a **protected, masked** project CI
variable, and `v*` tags are protected so release tag pipelines receive it too.
Only pipelines on protected refs (`main` and `v*` tags) receive it, so their
APKs, including every published preview, are signed by one stable CI debug
identity:
- `build-metadata.json` `signing`: "Stable legacy CI debug identity";
- certificate SHA-256 `5bec28281b4c1405f9ee47590c40665a24b0f984fc0d6b8854a3458e8db0a71d`
  (`STABLE_CI_DEBUG` in [the release inventory](ANDROID_RELEASE_INVENTORY.json)).

Merge-request and other unprotected pipelines do not receive the variable and
still sign with a discarded ephemeral key, so their job-artifact APKs cannot
update a preview in place. Previews published before the variable was set
(through `v0.5.0-dev.4e4d2979`) were signed by ephemeral keys and cannot be
updated in place either. Besides the CI variable, the private keystore is kept as
`ci-debug.p12` (PKCS12, alias `androiddebugkey`, mode `0600`) in the owner's
canonical signing directory `~/.config/gitlab-mobile/android-signing`. Never
copy it into the repository, artifacts or prompts.

An Android update requires the same application ID, a compatible signer and a
`versionCode` at least as high as the installed build. A preview signed by an
unrelated historical debug key cannot update in place and reports
`INSTALL_FAILED_UPDATE_INCOMPATIBLE`. Do not automatically uninstall it or clear
its data: doing so loses local accounts and drafts. Preserve the installed app
until a matching historical signer is available or data loss is explicitly
accepted.

Neither the local development signer nor the current CI debug-signing lane is
Play App Signing. Play publication and production signing remain unconfigured.

### Distribution channels and versionCode

`tool/bootstrap.py` generates two Android product flavors, `gitlab` and `play`
(dimension `distribution`). The `gitlab` flavor keeps the application ID
`io.gitlabmobile.gitlab_mobile`, so installed previews keep updating in place;
the `play` flavor uses `app.mergeline` (see `docs/STORE_LISTING.md`). The
flavor reaches Dart as Flutter's `appFlavor` and decides how the app is
updated. Every Android build
therefore names one: `flutter build apk --flavor gitlab`, `flutter run --flavor
gitlab`. iOS has no flavors and builds as before.

`ci/build_android.sh` builds the `gitlab` flavor with `--build-number` set to the
project's `CI_PIPELINE_IID`, which only grows, so each CI APK has a higher
`versionCode` than the last (the pubspec's `+5` is used only for local builds).
`build-metadata.json` records `channel`, `build_type`, `version_name` and
`version_code` next to `signing`. The `play` flavor is not built in CI; its
store signing and listing are `NOT_RUN`.

### In-app updates

- **`gitlab` builds** look for an update in this project's releases on GitLab.com (project 86648389), anonymously. An interceptor strips every credential header, so no account token ever goes there.
  - A release counts when it links a `gitlab-mobile-<sha>-release.apk` and its `build-metadata.json` from the same package. The metadata must say `channel: gitlab`, `build_type: release` and a higher `version_code`.
  - The metadata is fetched within 64 KiB and must match the SHA-256 GitLab records for it.
  - Debug previews and older releases without these fields are never offered.
- **Download and install:** the APK goes to the app cache's `updates/`, and its size and SHA-256 are checked against the package file. The generated `gitlab`-flavor `AppUpdateChannel` then hands it to the system installer through `UpdateFileProvider` (cache `updates/` only, `REQUEST_INSTALL_PACKAGES`). Android asks once to allow installs from the app, and the user confirms every install.
- **`play` builds** call Google Play's in-app update API (flexible) instead and declare no install permission.
- **What a release needs:** publishing a gitlab-channel release requires its pipeline's release APK and metadata as package links.
- **Verification:** device and Play verification are `NOT_RUN`.

## iOS and product acceptance

An iOS binary needs a macOS runner with an appropriate Xcode toolchain. App Store/TestFlight deployment also needs signing and distribution credentials. Neither has been assumed or enabled. G0 acceptance additionally needs actual private-project access, device secure-storage/backup tests, account switching, network failure and accessibility evidence on Android/iOS. These remain separate from green CI.

## Isolated Android emulator UI QA

The content-editor fixture also supplies stateful project/group title/Markdown
updates, explicit permission revocation and actor expiry, revision conflicts,
absent description widgets and lost acknowledgements. Controls and logs belong
only to the synthetic QA entrypoint. Production content editing never falls
back to these records. API, editor and fixture regressions run in the normal
Flutter test job; real private content updates remain a separate acceptance lane.

The QA-only target `tool/emulator_ui.dart` renders the production project,
environment/deployment, schedule and project/group Work Item pages through the existing synthetic
transport. It requires `EMULATOR_UI_QA=true` and displays a persistent synthetic
data banner. Its memory-only accounts use test credentials; every API request
stays in the fixture adapter. Normal `lib/main.dart` has no fixture fallback.

Use a project-owned AVD with an already installed official Android image and
an explicit `emulator-*` serial. Confirm `ro.kernel.qemu=1` and the AVD name
before installation or input. Do not use an unqualified `adb` command or copy
accounts from a physical phone. For the current isolated AVD:

```sh
.fvm/flutter_sdk/bin/flutter run --profile --flavor gitlab -d emulator-5580 \
  -t tool/emulator_ui.dart --dart-define=EMULATOR_UI_QA=true \
  --dart-define=PERF_LABEL=synthetic-emulator
```

Observe the actual Android Share chooser, verify its canonical URL and dismiss
it without selecting a recipient. Cover Star/Unstar, environment navigation,
schedule confirmation/cancellation, session invalidation and narrow/large-text
layouts. Group-list QA covers descendant paths, bounded continuation, scope/state/search/type/order controls and root-owned type selection. Inbox QA covers single completion, clear-all cancellation/completion and retained scroll behavior. Work Item QA also covers cancellation, close/reopen with fresh readback,
and removing a confirmation after session ending. Notification QA covers lazy
project/group personal reads, explicit subscribe/unsubscribe, backend rejection,
expired-actor preflight, uncertain one-send, failed-refresh retention with stale
controls disabled, and session invalidation. Activity QA covers both scopes,
all six filter/order combinations, continuation, refresh and session invalidation.
Check the complete above-field activity labels in screenshots at both default
size and 320dp/2× text; passing geometry tests or a successful tap alone does
not establish correct label painting. Restore any emulator font/display changes
after the run. The existing
scroll sampler emits numeric frame summaries only; emulator fixture timings
do not establish physical-device performance or live GitLab acceptance.
Production APK login/cold-start and the anonymous `public_api_smoke` suite are
recorded separately. This manual lane is not a new CI emulator job.

Official references:
- <https://docs.gitlab.com/ci/yaml/workflow/>
- <https://docs.gitlab.com/ci/testing/unit_test_reports/>
- <https://docs.gitlab.com/user/packages/generic_packages/>
- <https://docs.gitlab.com/ci/jobs/ci_job_token/>
- <https://developer.android.com/studio>
- <https://developer.android.com/studio/publish/app-signing>
- <https://docs.flutter.dev/deployment/android>

## GitHub branch sync

GitLab is canonical. The GitHub repository `akari-sora/gitlab-mobile` is a mirror: the GitLab push mirror sends protected branches (`main`) there, and GitHub Actions is disabled. Cloud Claude sessions work on the GitHub mirror and push `claude/*` branches; nobody commits to GitHub `main`.

A pipeline schedule with variable `GH2GL_SYNC=1` runs only the `gh2gl_sync` job (every other job is skipped for that pipeline). It runs `ci/gh2gl_sync.sh`, which:

- fetches `claude/*` and `main` from the public GitHub mirror and the same refs from GitLab;
- pushes a GitHub `claude/*` branch to GitLab only as a fast-forward (`--force-with-lease` on the GitLab sha). If GitLab has commits GitHub lacks (review fixes, a rebase) or GitHub rewrote history, the branch is skipped with a warning and stays as it is on GitLab;
- skips branches already contained in `main` (including squash merges, checked with `git merge-tree`), so a merged branch is not revived;
- opens a draft MR to `main` for a new branch through push options, and marks the MR draft again when the branch is updated, so a reviewed head does not change silently;
- saves commits pushed straight to GitHub `main` and missing from GitLab `main` as `rescue/github-main-<sha8>` with a draft MR. This only works when the schedule runs before the next push-mirror update overwrites GitHub `main`;
- collects per-branch push errors and fails the job at the end; never pushes to a protected branch and never deletes a branch.

It pushes with a project deploy key that has write access to unprotected branches only. The private key is the protected file variable `GH2GL_DEPLOY_KEY`, scoped to the `gh2gl-sync` environment, so only this job receives it; the key is copied into a temporary directory that is removed on exit. A backup is in the owner's password manager. To stop the sync, deactivate the schedule.

Known limits: pipelines for synced branches run the branch's own `.gitlab-ci.yml` with the identity of the deploy key's creator, as any pushed branch would; only push to the GitHub mirror from accounts you trust. After a branch is merged, start new work on a new branch.
