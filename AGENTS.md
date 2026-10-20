# Development contract

Build a mobile-first Flutter GitLab client for Android/iOS. No desktop-first layout and no WebView wrapper.

Read README.md, docs/CI.md and docs/ROADMAP.md before work. The current implementation is the G0 PAT/private-repository reader. Do not mark G0 accepted based only on compilation or mocked API tests.

## Identity and content

An instance includes scheme, host, port and installation subpath. Account identity is instance plus numeric user ID. Project identity also includes numeric project ID. Bind caches and responses to the account generation. Never activate or display a stale response after switching accounts.

404 is ambiguous: inaccessible and nonexistent private resources cannot always be distinguished. Show the current account, instance and resource plus explicit retry/account-switch options. Do not silently rotate through accounts.

Never commit tokens, credentials, private repository content or private traces. Do not forward API authorization through redirects or third-party URLs. Use synthetic credentials in tests. Production screens must not fall back to mock data.

The only persisted repository-derived content is opt-in AI chat history: redacted display models encrypted per account with AES-256-GCM under Application Support. Bind each file to its account and file name with AAD, use a fresh nonce, and never persist provider replay output. Enforce 512 KiB per conversation, 50 conversations and 16 MiB per account, 64 MiB per device, and 7/30/90-day retention (30 by default). `AiHistoryCoordinator.instance` owns reads, writes, recovery and cleanup; it must distinguish an unavailable secure store from an absent key, never delete or replace data on `unavailable` or `keyMissing`, and perform orphan cleanup only after the current account list loaded successfully. Account removal is `clearSecureDrafts → clearAccountArtifacts → clearRecentProject → clearAiAccountData → session.remove`; write the AI tombstone before cleanup, delete it last, and keep the account plus a successfully written tombstone on cleanup failure. If the initial marker write itself is unavailable, keep the account and require retry; do not claim a durable marker exists before a write succeeds. Recovery must respect the conversation-before-index write order and file-before-index eviction order, rebuild/drop/restore index entries safely, remove stale temporary or individually unreadable files with a user-visible notice, and reapply retention and capacity. The complete key, file and crash-recovery contract is in `CLAUDE.md` under Persistence.

## Validation

Use the pinned Flutter SDK and committed dependency lock. Run analysis and tests against the actual submitted source. Do not rewrite source inside CI and claim the rewritten code was tested. Missing tests, interrupted runs and unavailable devices are not passes.

Preserve backup/cleartext/keychain restrictions when generating native platforms. Linux template generation is not an iOS build. Do not enable or reconfigure unrelated runners.

Each completed task reports its commit, pipeline/job evidence, tests actually run and remaining gaps. No G0 acceptance without real private-project integration and Android/iOS device evidence.

## Android local signing

All local Android debug, profile and release builds use the same stable development signer so an APK can update another local APK without clearing app data. Read `docs/ANDROID_SIGNING.md` before an Android build.

- Canonical host directory: `~/.config/gitlab-mobile/android-signing` (`/Users/iml1s/.config/gitlab-mobile/android-signing` on this host).
- Current public certificate SHA-256: `a15c11c804bd8b40cebf052747bfea91542568989af0b7a092efcfcb7ebff434`. Treat a mismatch as a signing-identity change and stop.
- Private files: `gitlab-mobile.p12` and `signing.properties`. Keep the directory mode `0700` and both files mode `0600`.
- Create the identity only through the explicit one-time `python3 tool/android_signing.py init` command. Never replace an existing or incomplete identity during an ordinary build.
- `python3 tool/bootstrap.py` installs the signing loader in regenerated native templates. To update an existing template directly, run `python3 tool/android_signing.py configure android/app/build.gradle.kts`. For another host or worktree, point `GITLAB_MOBILE_SIGNING_PROPERTIES` at an absolute `signing.properties` path.
- A missing signing identity is a build error. Do not silently create a random debug key, uninstall the installed app, clear app data or rotate the signer.
- Never commit, attach, print, paste into prompts/MRs/memory, or copy into `artifacts/` the private key or passwords. Record only the public certificate SHA-256 when evidence needs a signer identity.
- This shared local signer is for development APK continuity. It is not Play App Signing, a store release, or production acceptance. CI signs through its separately documented lanes: protected refs build release APKs with the protected stable CI identity, and every other pipeline builds debug APKs with an ephemeral debug-only key.
- A one-time API 33+ migration from the known earlier local debug signer is documented in `docs/ANDROID_SIGNING.md`. It requires that old private key and native data-retention proof; it cannot migrate an APK signed by an arbitrary CI key.
- The recovered earlier local signer (public certificate SHA-256 `64500eefad1aeb8e163c2ceeaa78b39ce013849f1a75596dd1b477fc5d023736`) is `legacy-local-debug.p12` with lineage `legacy-local-rotation.lineage`, both in the canonical directory at mode `0600`. Use it only for a special migration bridge with that existing lineage, never for ordinary builds or a rotation.
- Before any signing, packaging or recovery conclusion, read `docs/ANDROID_RELEASE_INVENTORY.json` and follow the lookup order in `docs/ANDROID_SIGNING.md`: inventory and canonical directory names/modes, then retained APK certificates, then own worktrees and receipts, then current-project CI metadata. Do not check only CI, and do not conclude a key or APK is lost: a missing file is "not found at that path", and anything unverified stays `unknown`. The inventory is public metadata, not a private key backup.
- A device's installed signer is unknown until read from that device. A generic install failure does not prove a signer mismatch.
- Every new packaged or released APK gets an inventory entry (or linked receipt): APK SHA-256 and size, certificate SHA-256 per scheme, application ID, versionName/versionCode, debuggable and SDK range, source commit, build lane/variant, Dart entrypoint, QA/benchmark flags (enabled or disabled), and a durable URL or explicit `local-only`.

Use only the project-owned Android emulator for this repository's device checks. The physical phone is reserved for the charging session.
