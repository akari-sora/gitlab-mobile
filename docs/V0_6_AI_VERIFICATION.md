# v0.6 AI verification ledger

MR1 implements the plain-Dart security core only. `MERGELINE_AI_ASSISTANT`
defaults to false. No AI controllers, settings, entry points, or provider calls
are wired into the application by this slice (plan §9.1–§9.2).

## Evidence boundaries

| Lane | MR1 scope / status |
| --- | --- |
| Endpoint policy, SSE, failures, redaction, transcript and provider contracts | Synthetic unit tests; local results are in the uncommitted root `RESULT.md` |
| Existing Flutter behavior | Full suite against the submitted source; see `RESULT.md` |
| Localization | zh-TW and English authored; other 22 catalogs are temporary English placeholders per MR1 packet |
| GitLab/private-resource integration | NOT_RUN; MR1 does not use the GitLab API |
| Native provider conformance / P0 | NOT_RUN; plan §9.4, before MR2 |
| Android/iOS, accessibility and AOT performance | NOT_RUN; subsequent device/release lanes |
| Pipeline / job URLs | NOT_RUN; this packet prohibits commits and pushes |

## Later MR evidence

Record the exact source commit and pipeline/job URLs for each stacked MR; never
reuse an earlier MR's pipeline as proof for later source (plan §8.7).

- MR2: three wire adapters, lossless replay, synthetic fixtures and P0 evidence.
- MR3: settings stores, encrypted history and account-removal recovery.
- MR4: read-only tools, redaction across every outgoing runner path, live-secret
  rotation and frozen-prefix validation, budgets and lifecycle races.
- MR5: settings, versioned consent and model-sensitive data-use disclosure.
- MR6: chat, context entry points, draft insertion, mention checks and reports.
- MR7: gate enablement, native declarations, full device/accessibility evidence
  and store/release checks.

## Provider matrix (no live calls in MR1)

| Provider / format | Model | State |
| --- | --- | --- |
| Native OpenAI / Responses and Chat | Not selected | NOT_RUN |
| Native Anthropic / Messages | Haiku only during later authorized P0 | NOT_RUN |
| OpenCode Go / Responses, Chat and Messages | Exact model × format requires separate P0 proof | NOT_RUN |
| Ollama / LAN cleartext | Not selected | NOT_RUN |
| Other presets and custom endpoints | Not selected | NOT_RUN |

A model or preset definition is configuration metadata, not verification. Native
and proxy evidence remain separate. Secrets, private bodies and private traces
must never be attached to this ledger.
