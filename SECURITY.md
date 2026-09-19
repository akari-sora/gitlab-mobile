# Security notes

This is a development preview, not a security-audited production client.

Credentials are stored through the platform secure-storage plugin. G0 does not persist private repository code or logs to disk. An API client belongs to one immutable account session, rejects unexpected API targets, and does not follow credential-bearing redirects.

Android runner generation disables cleartext HTTP and backup, and installs backup/data-extraction exclusions. iOS runner generation adds keychain entitlements. These configurations still require verification on actual supported devices and backup/restore flows.

Never post tokens, private source, private logs, signing keys or account dumps in a public issue or commit. Report vulnerabilities privately to the repository owner using an agreed private channel. No monitored security inbox or disclosure SLA is claimed here.

CI builds use synthetic API fixtures. Preview delivery uses GitLab's short-lived CI_JOB_TOKEN; personal tokens are not embedded in the repository, build, or delivery scripts. The debug APK is not a production-signed distribution.
