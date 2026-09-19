# Development contract

Build a mobile-first Flutter GitLab client for Android/iOS. No desktop-first layout and no WebView wrapper.

Read README.md, docs/CI.md and docs/ROADMAP.md before work. The current implementation is the G0 PAT/private-repository reader. Do not mark G0 accepted based only on compilation or mocked API tests.

## Identity and content

An instance includes scheme, host, port and installation subpath. Account identity is instance plus numeric user ID. Project identity also includes numeric project ID. Bind caches and responses to the account generation. Never activate or display a stale response after switching accounts.

404 is ambiguous: inaccessible and nonexistent private resources cannot always be distinguished. Show the current account, instance and resource plus explicit retry/account-switch options. Do not silently rotate through accounts.

Never commit tokens, credentials, private repository content or private traces. Do not forward API authorization through redirects or third-party URLs. Use synthetic credentials in tests. Production screens must not fall back to mock data.

## Validation

Use the pinned Flutter SDK and committed dependency lock. Run analysis and tests against the actual submitted source. Do not rewrite source inside CI and claim the rewritten code was tested. Missing tests, interrupted runs and unavailable devices are not passes.

Preserve backup/cleartext/keychain restrictions when generating native platforms. Linux template generation is not an iOS build. Do not enable or reconfigure unrelated runners.

Each completed task reports its commit, pipeline/job evidence, tests actually run and remaining gaps. No G0 acceptance without real private-project integration and Android/iOS device evidence.
