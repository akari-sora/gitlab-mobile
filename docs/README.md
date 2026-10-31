# Documentation

Where to find what. Start with [Plan and status](PLAN_STATUS.md) for the current state and the next steps; the [changelog](../CHANGELOG.md) lists what each release changed.

## Product

| Document | What it covers |
|---|---|
| [Plan and status](PLAN_STATUS.md) | What is being built, in what order, and where each piece stands. Updated in the MR that changes a status. |
| [Roadmap](ROADMAP.md) | Product scope and acceptance boundaries. |
| [Privacy policy](PRIVACY.md) | What leaves the device and where it goes (English and 繁體中文). The hosted copy linked from Google Play mirrors this file. |
| [Store listing](STORE_LISTING.md) | Google Play listing copy, trademark rules and the reviewer instructions (Demo mode). |
| [Play declarations](MR7_PLAY_DECLARATIONS.md) | Technical answers behind the Play data-safety, AI-content and permission declarations. |
| [UI redesign](UI_REDESIGN.md) | UX rules for the mobile layout; the v0.6 section supersedes the older root destinations. |

## Engineering

| Document | What it covers |
|---|---|
| [CI](CI.md) | Pipelines, runners, release flags and how preview APKs and releases are published. |
| [Android signing](ANDROID_SIGNING.md) | The local development signer and the CI signing lanes. |
| [Android release inventory](ANDROID_RELEASE_INVENTORY.json) | Machine-readable record of release artifacts. |
| [MR7 sandbox](MR7_SANDBOX.md) | The AI write sandbox: synthetic fixtures and the explicit live mode. |
| [MR6c runbook](MR6C_RUNBOOK.md) | Host tooling for background AI runs (off in released builds). |
| [Plans](plans/) | Detailed working designs (AI writes, cache and offline, MR6b/MR6c/MR7 breakdowns and decisions), mostly in Traditional Chinese. |

Contributors should also read [`CLAUDE.md`](../CLAUDE.md) (architecture, persistence, conventions) and [`AGENTS.md`](../AGENTS.md) (the binding development contract).

## Verification evidence

Synthetic tests, live API checks, emulator runs and physical-device runs are recorded separately; anything a ledger does not list is **NOT_RUN**.

| Ledger | Scope |
|---|---|
| [v0.6 AI verification](V0_6_AI_VERIFICATION.md) | The AI assistant, MR1 through MR7. |
| [Mobile parity and performance](MOBILE_PARITY_PERFORMANCE.md) | Web-parity and performance follow-up after v0.5 (plan: [MOBILE_PARITY_PERFORMANCE_PLAN](MOBILE_PARITY_PERFORMANCE_PLAN.md)). |
| [Mobile web parity ledger](MOBILE_WEB_PARITY_LEDGER.md) | Workflow-by-workflow parity with GitLab web. |
| [v0.5 verification](V0_5_VERIFICATION.md) | The v0.5 mobile UX overhaul. |
| [v0.3 verification](V0_3_VERIFICATION.md) | The v0.3 collaboration preview. |
| [v0.2 verification](V0_2_VERIFICATION.md) | The v0.2 API-backed screens. |
| [Receipts](receipts/) | Machine-readable QA receipts. |

## Audits

| Audit | Notes |
|---|---|
| [Audit report](AUDIT_REPORT.md) | Architecture, gaps, UI/UX and code quality (2026-09-21). The status block at the top lists what has since landed. |
| [GitLab web vs. mobile gap audit](GITLAB_WEB_VS_MOBILE_GAP_AUDIT.md) | Feature-gap analysis against GitLab web (2026-09-24). |

## Historical

| Document | Notes |
|---|---|
| [v0.2 continuation (2026-09-20)](CONTINUATION_2026-09-20.md) | Handoff record from the v0.2 period; superseded by the ledgers above. |

## Media

[`media/`](media/) holds the README showcase: the feature graphic, store screenshots and a short demo GIF, all taken in Demo mode with sample data. The full promo video is on [YouTube](https://www.youtube.com/watch?v=oXaaAxL1h_E).
