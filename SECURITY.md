# Security notes

This is a development preview, not a security-audited production client.

Credentials are stored through the platform secure-storage plugin. Repository-derived persistence is limited to encrypted editor drafts, recent-project IDs and names, transient artifact/attachment/media caches, the AES-256-GCM read cache (`read_cache/`, including verified terminal-job log tails), explicitly saved encrypted offline repository snapshots (`offline_repo/`), and opt-in encrypted AI chat history and write journal (`ai_history/`, `ai_write_journal/`); see [AGENTS.md](AGENTS.md) and [CLAUDE.md](CLAUDE.md). An API client belongs to one immutable account session, rejects unexpected API targets, and does not follow credential-bearing redirects.

Android runner generation disables cleartext HTTP and backup, and installs backup/data-extraction exclusions. iOS runner generation adds keychain entitlements. These configurations still require verification on actual supported devices and backup/restore flows.

Never post tokens, private source, private logs, signing keys or account dumps in a public issue or commit. Report vulnerabilities privately to the repository owner using an agreed private channel. No monitored security inbox or disclosure SLA is claimed here.

CI builds use synthetic API fixtures. Preview delivery uses GitLab's short-lived CI_JOB_TOKEN; personal tokens are not embedded in the repository, build, or delivery scripts. Protected-ref CI pipelines build a `gitlab`-flavor release APK signed with the stable CI preview identity (merge-request pipelines use a discarded ephemeral debug key), while the Google Play build is signed locally with the Play upload key; see [docs/ANDROID_SIGNING.md](docs/ANDROID_SIGNING.md) and [docs/CI.md](docs/CI.md).
