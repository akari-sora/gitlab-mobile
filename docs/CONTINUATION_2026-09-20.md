# Mobile v0.2 continuation — September 20, 2026

This record distinguishes implemented controls, synthetic tests, public live reads, authenticated connector calls and physical-device acceptance. None is interchangeable with the others.

## Product changes

The feature branch replaces the G0 sign-in, project list, navigation, file browser, review/composer and CI screens. The original project-list regression came from server-expanded default parameters in pagination Link headers; the production parser now preserves the original query and validates/extracts only a safe cursor.

The September 20 continuation also fixes job metadata disappearing when trace retrieval fails, distinguishes a pending/manual empty log, bounds rendered log line count, and refreshes pipeline job attempts on return after retry. Metadata/status/retry/artifact controls remain usable when an old completed log returns 404 or a log is too large.

## New visible-control regressions

`test/crud_controls_test.dart` adds stateful create/read/edit/delete paths for files, MRs, releases, labels and milestones; supported create/read/delete operations for branches and tags; pipeline run/retry/cancel/delete; job retry/new-ID/return refresh; manual play before trace exists; unavailable and oversized traces; and invalid calendar dates. It asserts changed data on subsequent reads, actual request methods/payloads, and disabled destructive confirmation before the exact name matches.

The first execution caught two test-selector/fixture mismatches (request-only tag_name accidentally echoed by the synthetic server, and job name identical to the stage label) and two strict-inference warnings. These were corrected without disabling or skipping tests. Final counts/status must be read from the successor pipeline, not inferred from this document.

## Real network evidence already completed

- Commit: `b00c91acad29ae03e8d93c18a32a10638bd3eae0`
- Pipeline: https://gitlab.com/aa22396584/gitlab-mobile/-/pipelines/2864617839
- Job: https://gitlab.com/aa22396584/gitlab-mobile/-/jobs/16608341459
- Suite: `tool/public_smoke.dart` using the production Dart HTTP/parsing/pagination code with a read-only interceptor removing authentication for public endpoints.
- Result: **6 PASS, 0 FAIL, zero writes.** Numeric project lookup; encoded namespace lookup; actual GitLab Link header plus second page; fixed-SHA tree and README; branches/tags/releases; missing file remains HTTP 404.
- Artifact: `public-smoke-output/report.json`.

This is actual GitLab.com network integration, not a fake adapter. It is **anonymous public-read evidence only**, NOT proof of PAT login, private repository access or live CRUD. The interceptor reads no credential; it blocks methods other than GET/HEAD and hosts other than the fixed GitLab.com API. The production client itself still requires credentials for normal app sessions.

## Remaining private CRUD gate

The supplied-PAT CI handoff was blocked before a pipeline was created. Do not encode, commit, relay, or otherwise bypass that restriction. The PAT suite remains NOT_RUN in this environment.

For an authorized local checkout with Flutter/Dart installed:

```sh
flutter pub get --enforce-lockfile
python3 tool/run_live_smoke.py
```

The local launcher prompts without echo, passes only a temporary file path to Dart, verifies the expected numeric account in the Dart suite, and removes the credential file on process completion/error. The suite creates a uniquely named private sandbox and cleans up only its exact ID/path. It never deletes this application repository. Check `smoke-output/report.json` for executed cases and any pending sandbox deletion; do not infer PASS from launching the command.

## Release boundaries

Android debug APK compilation, host-rendered synthetic-data UI screenshots, and Android/iOS template generation are CI evidence. Real Android/iOS touch/keyboard/back/secure-storage tests, iOS compilation/signing, supplied-PAT private CRUD and independent-reviewer approval remain outstanding. The application is a development preview, not an all-105-API or production acceptance claim. OAuth, native artifact downloading, uploads and push are not implemented.
