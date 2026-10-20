# v0.6 AI verification ledger

MR1 implements the plain-Dart security core only. `MERGELINE_AI_ASSISTANT`
defaults to false. No AI controllers, settings, entry points, or provider calls
are wired into the application by this slice (plan §9.1–§9.2).

## Evidence boundaries

| Lane | MR1 scope / status |
| --- | --- |
| Endpoint policy, SSE, failures, redaction, transcript and provider contracts | Original author reported synthetic tests passing; the original receipt was not retained in this checkout. FIX1 local checks are recorded in the handoff `RESULT.md`, which is not durable CI evidence. |
| Existing Flutter behavior | Original author reported a full-suite pass; no retained receipt or job URL is available here. FIX1 does not rerun the full Flutter suite. |
| Localization | All 24 catalogs contain AI translations at `bafe8ad`; FIX1 adds no messages. Catalog generation and translation guards are checked locally. |
| GitLab/private-resource integration | NOT_RUN; MR1 does not use the GitLab API |
| Native provider conformance / P0 | NOT_RUN; plan §9.4, before MR2 |
| Android/iOS, accessibility and AOT performance | NOT_RUN; subsequent device/release lanes |
| Pipeline / job URLs | NOT_RUN for FIX1; no new commit or pipeline is created in this handoff. |

## FIX1 security-core corrections

Review findings are consolidated in the local `RESULT.md` handoff, with failing
baseline regressions, the source locations and foreground acceptance tails. That
file is temporary; preserve its evidence in a durable MR/job receipt when the
owner submits the patch. No original full-suite claim is upgraded by these checks.

Redaction now detects exact secrets and structural patterns against the same
original input, merges overlapping spans and replaces once. This supersedes the
sequential replacement order in plan §5.6: a known prefix must not disable another
detector. A marker that contains a known secret causes `policyBlocked`. URL
userinfo uses the same marker, and rescanning a redacted result is idempotent.
Assignment identifiers and URL authorities are scanned once; JWT starts exclude
base64url continuation characters. PEM matching uses original-input offsets,
recognizes inline END and encrypted/PGP private-key blocks, and prefers a matching
END within 100 lines over an internal blank line. Without END, the first blank
line or the 100-line cap remains the boundary; a following BEGIN starts a new block.
Host timed regressions use a three-second bound for 2 MiB hostile input; the JWT test
first rejects a quadratic implementation at 32 KiB with a one-second bound. The
three-second full-size bound allows host contention in the parallel test suite. Emulator AOT <300 ms remains
NOT_RUN.

Transcript final-answer notes have explicit injection provenance and a dedicated
`addFinalAnswerNote()` operation. Ordinary `addFollowUp()` treats all text as user
content, including text equal to the system note. Both user-entry and tool-results
tails support follow-ups; frozen entries remain immutable.

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
