# v0.6 AI verification ledger

MR1 implements the plain-Dart security core only. `MERGELINE_AI_ASSISTANT`
defaults to false. No AI controllers, settings, entry points, or provider calls
are wired into the application by this slice (plan §9.1–§9.2).

## Evidence boundaries

| Lane | MR1 scope / status |
| --- | --- |
| Endpoint policy, SSE, failures, redaction, transcript and provider contracts | FIX1 source is commit `1abb72960ff544c803db75ce88302ac88380701d`; FIX2 source is commit `a1ba0432ef86440222f058bb74b07ca62b05a193`. Pipelines pending. FIX3 source is commit `8bf0bd6b43887d9b9df1a2e130d51c55b1e5f3b3`. FIX4 source is commit `bdefd6c431ad93ce0a9ef72fd4f139b69a2dec4c`. FIX5 source is commit `5da74eab3cb02fc6d327ce934b2d591fe8d8f541`. FIX6 source is commit `7b83c9205d4b2cf2fd2b62604742197b14cf18b4`. FIX7 source is commit `09a34cce4d8f2a4f9e714886a58ef3ae9f8c71be`. FIX8 is the commit that adds this sentence. Local synthetic checks do not establish CI acceptance. |
| Existing Flutter behavior | Original author reported a full-suite pass; no retained receipt or job URL is available here. FIX1 does not rerun the full Flutter suite. |
| Localization | All 24 catalogs contain AI translations at `bafe8ad`; FIX1 adds no messages. Catalog generation and translation guards are checked locally. |
| GitLab/private-resource integration | NOT_RUN; MR1 does not use the GitLab API |
| Native provider conformance / P0 | NOT_RUN; plan §9.4, before MR2 |
| Android/iOS, accessibility and AOT performance | NOT_RUN; subsequent device/release lanes |
| Pipeline / job URLs | FIX1 `1abb72960ff544c803db75ce88302ac88380701d` and FIX2 `a1ba0432ef86440222f058bb74b07ca62b05a193`: pipelines pending; no verified job URL retained here. FIX3 `8bf0bd6b43887d9b9df1a2e130d51c55b1e5f3b3`: pipeline pending. FIX4 `bdefd6c431ad93ce0a9ef72fd4f139b69a2dec4c`, FIX5 `5da74eab3cb02fc6d327ce934b2d591fe8d8f541`, FIX6 `7b83c9205d4b2cf2fd2b62604742197b14cf18b4`, FIX7 `09a34cce4d8f2a4f9e714886a58ef3ae9f8c71be` and FIX8: pipelines pending. |

## FIX1 security-core corrections

FIX1 corrections are recorded in commit
`1abb72960ff544c803db75ce88302ac88380701d` (pipeline pending). Preserve exact-source
test evidence and job URLs in the MR when submitting further corrections.
No original full-suite claim is upgraded by local checks.

Redaction now detects exact secrets and structural patterns against the same
original input, merges overlapping spans and replaces once. This supersedes the
sequential replacement order in plan §5.6: a known prefix must not disable another
detector. A marker that contains a known secret causes `policyBlocked`. URL
userinfo uses the same marker, and rescanning a redacted result is idempotent.
Assignment identifiers and URL authorities are scanned once; JWT starts exclude
base64url continuation characters.

Private-key detection collects every BEGIN and END marker in one scan of the
original input, independent of line structure, indentation, prefixes, JSON
newline escapes or body characters. Labels are `[A-Z0-9 ]*PRIVATE KEY` and
`PGP PRIVATE KEY BLOCK`; certificates and all other non-private markers are
ignored. One forward pass over the markers (FIX6) keeps a count of open BEGINs
per label: a BEGIN opens or joins the current range, an END closes one open
BEGIN with the same label, and the range ends only when every BEGIN in it is
closed, so nested and interleaved keys stay inside one range. Each range
includes one immediately following CR, LF or CRLF and uses `[REDACTED]`.

The rule fails closed in both directions, without a cap. **A BEGIN that never
meets an END with its label withholds everything after it**
(`[REDACTED:private_key_unterminated]`), including the rest of the text after a
stray BEGIN such as a `set -x` grep line or a documentation mention, even when
a complete key follows. **An END that closes no open BEGIN** (its key started
before this text, as in a log read from an offset; a foreign label; interleaving)
**withholds everything from the start of the input through it**
(`[REDACTED:private_key_unopened]`). Both are deliberate: any cap or heuristic
reopened a leak in rounds 1–6. `RedactionResult.withheldPrivateKeyContext`
reports either case so the assistant UI (MR6) can say why content was not sent.
An END overlapping the BEGIN marker it follows cannot close it, and a truncated
END counts as missing. No windows, line-extension scan, armor/base64 heuristics
or inspection cap remain. Spans merge with the other original-input detectors
using the existing overlap rule; the unterminated reason wins over the unopened
one, which wins over a plain range.

The fixed-delimiter regex cannot scan a variable label run across the next
candidate's hyphens; its backtracking visits each disjoint label run only a
constant number of times. A fixed five-hyphen lookahead also detects markers
sharing a delimiter, so a BEGIN that shares the hyphens of a closing END still
opens its own range. Marker collection and pairing are one linear pass; the
common span sort/merge is unchanged. Host growth regressions compare N with 4N
(N = 512 KiB for most inputs, 25,000 BEGINs and 2,000 sentinels for two of
them, so 4N stays near 2 MiB; fastest of three samples after warm-up)
and require at most 8x growth (quadratic work grows 16x) with a five-second
ceiling. Inputs cover alternating markers, long invalid labels, many BEGINs
without END, a single line and earlier JWT, assignment, inline and armor
attacks, plus many distinct labels. A pairing check compares 512 KiB with
4 MiB of short BEGIN/END pairs
(at most 14x; linear is 8x, quadratic 64x); a temporary quadratic pairing
mutation measured 47x and failed it. These are host JIT/coverage checks;
emulator AOT <300 ms remains NOT_RUN. Fixtures are synthetic unusable armor;
no usable private keys are generated or retained. Prefixed credential headers
remain recognized at identifier boundaries. Plain `ssh://git@host` remains
visible; passwords, opaque URL tokens and known secrets remain redacted.

Transcript final-answer notes have explicit injection provenance and a dedicated
`addFinalAnswerNote()` operation. Ordinary `addFollowUp()` treats all text as user
content, including text equal to the system note. Both user-entry and tool-results
tails support follow-ups; frozen entries remain immutable. FIX2 removes an
injected final-answer note before appending an ordinary follow-up, preserving any
identical user-authored note text.

## FIX3 private-key window regressions

FIX3 is commit `8bf0bd6b43887d9b9df1a2e130d51c55b1e5f3b3`.
The new regressions were run against the unchanged FIX2 scanner first: 15 tests
failed, covering the three unterminated-prefix shapes crossed with OpenSSH,
PKCS#8 and traditional RSA-4096 armor, oversized PGP armor, split headers, END at
the boundary and extension-cap protection. Each matrix cell tests a split body,
BEGIN and END; body lines must leak zero times. Fixtures are synthetic,
structurally armored data, never real private keys. PGP fixtures exceed 64 KiB,
include headers and CRC, and cover LF/CRLF. A separate ledger assertion failed
before correcting FIX2's committed-source identification above.

FIX3's window/extension behavior and one-second PEM timing expectations are
superseded by FIX4's marker-pairing rule and growth checks above. Its retained
receipt is historical evidence, not validation of the current patch.

## FIX4 marker-pairing regressions

FIX4 is commit `bdefd6c431ad93ce0a9ef72fd4f139b69a2dec4c`. The unchanged FIX3 scanner failed all ten new formatting-shape matrix
tests before replacement. The matrix covers ten shapes × four prefixes × six
key types × four split placements × LF/CRLF (1,920 cases). Every cell records
leaked body-line counts, including baseline controls that already passed.
The shapes include YAML/tab indentation, quotes, trailing spaces, BEGIN trailing
space, diff minus/plus, timestamps, JSON escaped newlines and body punctuation.
The prefixes are none, set-x grep, head-3 PKCS#8 and documentation; key types
are OpenSSH, PKCS#8, traditional RSA, encrypted traditional RSA, EC and PGP over
64 KiB. Separate edges cover documentation markers, truncated END, CR/LF/CRLF,
certificate chains, shared delimiters, nested BEGINs, differing END labels,
unbounded missing-END
suppression and overlap/idempotence. Foreground acceptance output and the before
and quadratic-mutation logs are recorded outside the repository. Full-suite, CI, live-provider and device gates remain separate.

## FIX5 pairing regressions

Round-5 review (Codex; Opus independently) found that a BEGIN sharing the five
hyphens of an already closed END was skipped, exposing the whole second key.
FIX5 skips only BEGINs wholly inside an earlier range, absorbs further ENDs
before the next uncovered BEGIN and redacts from the start of the input through
leading ENDs. Regressions: closed END plus shared-delimiter BEGIN with and
without its own END, a chain of three shared delimiters, a foreign END label
inside a key, and a key tail without its BEGIN. Two temporary mutations (the
previous skip rule; no END absorption) each fail their regression.

## FIX6 label-balanced pairing

Round-6 review (Codex) found that three interleaved keys still exposed lines of
the second key between the first END and the third BEGIN; Opus found the same
class for a log read from an offset inside interleaved keys. FIX6 replaces the
position pairing with the label-balanced pass above and redacts from the start
of the input through any END that closes nothing. Regressions: three
interleaved keys, a cut-off second key of the same label, mid-read interleaving
with the same and with different labels, a foreign END inside a key, and the
FIX4 matrix with its prefixes (zero leaked lines; a prefix holding a stray BEGIN
now withholds the rest, by contract). Growth tests were widened so a quadratic
pairing mutation fails reliably.

## FIX7 fragments and the known limit of marker pairing

Round-7 review (Codex; Opus as a Minor) showed a text cut at both ends where the
only BEGIN belongs to one key and the only END to another key with the same
label: `A_TAIL / BEGIN (B) / B_HEAD / END (A) / B_TAIL`. Its markers are
identical to plain text around one complete key, so no pairing rule over the
markers alone can protect it without hiding the context of every key. The
two-direction fail-closed rule above therefore holds for complete sources only.

`Redactor` has two entry points, so every caller states what it passes:
`redactSource` for a complete source and `redactFragment` for text cut from a
larger source (FIX8; FIX7 had an optional `fragment` flag that a caller could
forget). A fragment is withheld whole as `[REDACTED:private_key_fragment]` (and
sets `withheldPrivateKeyContext`) when it holds a private-key label anywhere,
including a marker whose hyphens were cut, or when its first line looks like
the end of a cut marker (uppercase letters, digits and spaces followed by one to
five hyphens, such as `IVATE KEY-----` or `--`) or its last line ends like the
start of one (one to five hyphens, at the line start or after whitespace,
followed by uppercase letters, digits and spaces, such as `-----END RSA PRIV`,
an indented `  --` or a prefixed `<time> -----END RSA`). This over-redacts some
fragments: any whose last line ends with whitespace, one to five hyphens and a
run of uppercase letters, digits and spaces, for example a Markdown rule `---`,
`curl -X POST`, `gcc -O2`, `a - B` or a deleted blank diff line `-`; that is
deliberate.
Other fragments use the ordinary rules. Regressions cover the round-7 shape, single BEGIN/END
markers in a fragment, a marker-free fragment and the placeholder collision
check; the same text as a complete source keeps its context.

Invariants for the context builders and tools (MR4), in addition to those
above: redact a complete source (a whole file, a finished job's whole trace)
before cutting excerpts from it; a running job's trace is redacted with
`redactSource` over the whole text accumulated from offset 0 (a prefix of the
source, whose open end the unterminated rule protects); use `redactFragment`
only for line-aligned inputs cut from a larger source and not redacted whole
first (a diff hunk, a line range, a search result blob); keep the
sensitive-path filter for diffs. Residual: fragments cut at byte offsets can
still expose a key when the fragment holds no marker at all, or when the key is
on a single line: for `\n`-escaped JSON, a cut inside either marker that removes
the `PRIVATE KEY` label; for a space-joined key (`echo $KEY`), a cut that starts
inside its BEGIN marker. Line-aligned inputs always include a whole marker line
when they include any part of one.

Invariants for the context builders and the runner (MR4): strip ANSI escape
sequences before redaction (a coloured grep can split a marker); redact the
complete fetched text before truncating it; keep each redaction input at or
below 2 MiB (an identifier run of 4 MiB or more overflows the regex stack and
fails closed as `policyBlocked`).

## Later MR evidence

Record the exact source commit and pipeline/job URLs for each stacked MR; never
reuse an earlier MR's pipeline as proof for later source (plan §8.7).

- MR2: three wire adapters, lossless replay, synthetic fixtures and P0 evidence.
- MR3: settings stores, encrypted history and account-removal recovery.
  `SecretSetId` uses a process-local HMAC key and must not be persisted.
- MR4: read-only tools, redaction across every outgoing runner path, live-secret
  rotation and frozen-prefix validation, budgets and lifecycle races.
  Expand the best-effort corpus for camelCase secret names, `PGPASSWORD`, Ruby
  hash assignments, SFTP userinfo and passwords with unencoded URL slashes.
  Before enabling the relevant paths, detect OpenRouter binding failures inside
  bounded `error.metadata.raw`, accumulate Anthropic `server_tool_use`
  `input_json_delta`, and never freeze an empty Anthropic content array. Add a
  formal decode-to-next-request replay-chain test using the sanitized recordings.
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

---

The preceding tables retain MR1 historical status; MR2 packet and offline
evidence are recorded below and do not upgrade MR1 to provider acceptance.

## AI assistant verification: MR2

MR2 implements the three wire adapters on top of MR1. Its review rounds
(two by Codex, Opus and Argon, a third by Codex and Opus, then Opus) are
folded into
the single MR2 commit that contains this section, so no intermediate state with
private launcher configuration reaches the remote. The assistant remains
unreachable from the UI. This ledger distinguishes
local offline adapter evidence from the supplied P0a provider evidence. No
provider traffic, credential lookup, Android build, device check or CI pipeline
was performed for MR2. P0b is **NOT_RUN**.

## Offline implementation and evidence

- Chat Completions: flatMap messages, parallel tool assembly, finish-reason
  independent tool detection, EOF compatibility, usage, refusal, reasoning,
  extension semantics, and a 1 MiB extension budget. Unknown fields replace
  whole values; only documented text fragments concatenate. Reasoning details
  merge only adjacent matching type/index entries, and encrypted details remain
  separate. Gemini extra_content uses the last complete non-empty object.
- Responses: store:false, optional encrypted-reasoning include, every terminal
  output item preserved in order (including id, phase, unknown fields and
  encrypted_content). output_item.done is not the replay source: P0a observed
  different ciphertext in the terminal event. Partial or failed tool calls
  cannot produce a completed turn.
- Anthropic: lossless ordered content blocks, thinking signatures (including
  omitted-display thinking), redacted/unknown/fallback blocks, latest non-null
  usage merging, and complete tool input. Official fallback replay pruning also
  removes discarded client calls from the executable call list. Tool results
  precede follow-up text within a single user message; adjacent user messages
  are rejected. No thinking parameter or binding beta header is sent.
- Frozen entries cache flatMap JSON fragments at freeze time. Actual transport
  requests splice those serialized fragments without re-encoding them. Segment
  system/tools/encoding capabilities are bound on first encode. Tests compare
  prefix bytes across requests, clipped new tool results and retries, plus
  one checked-in parallel-tools/results/follow-up golden per format.
- Models: shared bounded decoding, exact same-origin catalogue override,
  checked pagination (including override preservation), maximum three pages,
  and explicit truncation. Catalogue access proves only catalogue access.
  OpenRouter key checks use the separately allowlisted GET /key path.
- HTTP errors are parsed within MR1's 64 KiB bound and converted to safe typed
  failures; provider bodies are not retained in exceptions. Redirect,
  authorization, byte/time budget and rate-limit policies remain enforced.

Review-round acceptance output is recorded outside the repository. The submitted
source is tested directly with pinned Flutter
3.47.2 and --no-pub; no source rewriting or new dependencies are involved.

## Fixture provenance and privacy

`test/ai/fixtures/recorded/index.json` inventories **82 RECORDED calls** from
2026-10-20: 70 SSE responses and 12 HTTP-error responses, plus their request
JSONC files. Headers record path, model and direct/proxy/local route. The
source is the supplied `p0a/fixtures` packet; no provider was contacted to
produce these MR2 copies.

Every opaque provider value was replaced with a synthetic value before writing:
thinking signatures, encrypted reasoning (including Ollama plaintext in that
field), message/response/item/tool/request IDs, obfuscation, fingerprints and
non-null account identifiers. The 554 replacements are consistent across the
entire request/response corpus, preserve lengths/character classes/ID prefixes,
and cannot authenticate or replay against a real provider. Field order,
whitespace and event order remain, apart from provenance comments and these
replacements. See the recorded fixture README. Both source and output passed
the forbidden-prefix scan before copying. No key was read for sanitization.

All 70 recorded SSE files run through each adapter with byte-by-byte,
deterministic random and UTF-8-crossing chunks. Interrupted captures must fail
without a frozen output; complete captures must emit one start/finish. Responses
are compared to their complete terminal output. Recorded errors exercise the
real error-envelope shapes. Synthetic focused tests cover malformed streams,
repeated starts, post-terminal data, refusal, truncation, extension semantics,
fallback, binding rollover, header stability and safe catalogue handling.
The three `fixtures/golden/*.json` files and inline focused streams are
**synthetic**, not provider recordings.

## Supplied P0a findings and addendum handling

The P0a report/addendum describes authenticated checks against direct
Anthropic Haiku, OpenCode Go Responses/Chat/Messages, and local Ollama
Chat/Responses. Required A/R loop, follow-up and replay cells passed in those
supplied recordings; Anthropic prefix mutation and Responses corrupted
ciphertext controls returned 400. This is historical packet evidence, not a
live MR2 adapter check or blanket verification of every preset.

1. **OpenCode Go headers:** AiWireClient requires a caller-owned conversation
   ID and sends it unchanged across segments as x-opencode-session, with
   User-Agent Mergeline/<version>. New conversations supply new IDs. Transport
   allows only these additional headers and rejects injected header lines.
   Zen's session requirement remains NOT_VERIFIED; no unsupported policy or
   provider claim is inferred. Go is intended for coding-agent traffic; its
   settings disclosure belongs to the later settings/UI MR.
2. **Unknown-model and envelope shapes:** nested OpenAI errors, Anthropic
   type:error envelopes, and model-plus-error Responses envelopes are accepted.
   Identifiable model-unavailable HTTP 400 errors map to notFound, never to a
   retryable 5xx failure. MissingSessionID remains a safe invalidResponse.
3. **Any binding 400:** a bound-to-different-conversation error sets
   requiresNewSegment and permanently invalidates that segment for replay,
   regardless of the server's path. MR4 must make a fresh re-redacted projection
   (§4.4 plus addendum); the adapter never repairs a frozen prefix by index.
4. **Empty final answers:** complete reasoning-only or empty responses remain
   valid completed turns with zero text; no answer is fabricated. MR4's
   tool-budget/no-answer terminal state and MR6's localized UI remain deferred
   to those MRs, as required by the addendum.
5. **Output budgets:** requests default to 4096 and reject limits below 2048.
   The MR5 settings limit/minimum and MR6 truncation guidance remain later work.

The source report also confirms proxy/header differences, both Anthropic auth
styles, and Ollama ignoring tool_choice. FIX1 enables streaming usage only for
the recorded OpenCode Go/Ollama Chat paths, and tool_choice only for the
recorded OpenCode Go Messages/Responses paths. Zen and LM Studio retain their
conservative caps.
Raw IDs/ciphertext are replayed without provider-specific conversion. Reasoning
content remains in memory only, including plaintext Ollama reasoning.

## Opt-in P0b harness and remaining gates

`tool/run_ai_live_smoke.py` directly connects approved 1Password subprocess
stdout to pinned Dart stdin without Python reading credential bytes. Fixed
Ollama targets run keyless without starting 1Password. The Dart tool accepts
only reviewed target IDs, sends synthetic fixture content and writes only
scanned metadata under ci-output/ai-live/. Credential text, provider bodies and
opaque output are absent from reports. Tests mock subprocesses and exercise
the pure output guard without running the live entrypoint.

Credential references for keyed targets are local-only configuration in
`~/.config/gitlab-mobile/ai-smoke.json`, represented as a JSON object that maps
reviewed target IDs to `op://` references. Missing targets and invalid reference
types fail before a subprocess starts. The repository contains no local vault or
item identifiers, and launcher errors never print references or secret values.

Implemented smoke scenarios cover text/usage, parallel tools, replay/follow-up,
cancellation and unknown models. A second tool step is explicitly NOT_RUN if
the model finishes after the first step. Runner-dependent projection, model
switching and closing terminal-state checks remain marked NOT_RUN until MR4
supplies the bounded runner (plan Appendix D.5). P0b has not been executed for
any target in this task. MR4 consent/revision/secret reconciliation and MR6 UI
are not implemented here. MR7 integration, device/store evidence and all G0
acceptance remain unclaimed. Pipeline/job evidence is recorded with the MR2
merge request.

## MR2 FIX1 offline review fixes

The patch buffers fragmented text/reasoning/tool arguments and counts Chat
extension JSON incrementally, including keys, escaping and replaced values.
Timed regressions bound hostile tiny-delta processing; they measure host
decoders, not mobile frame pacing. Responses no longer accumulates unused
intermediate output. Anthropic unknown blocks preserve their raw start JSON.
Chat requires a started stream plus a finish reason before `[DONE]`; legacy
function_call turns are consistently rejected because no legacy result shape
is supported. Cached Chat prompt usage is split into uncached and cached
counts so the usage total does not double-count cache hits.

A validated terminal success cancels upstream immediately. Binding HTTP 400s
include thinking-signature variants and invalid_encrypted_content; all six
recorded binding fixtures now have explicit rollover assertions. Genuine
server_error SSE events remain server failures. Proxy context-limit wording
is recognized without reclassifying transport/server failures as binding 400s.

Offline injected smoke tests reject unfinished text/tool follow-ups and require
actual reasoning material when claiming reasoning replay. Ordered frozen
prefixes are checked against the actual encoded transport request bytes.
Missing required reasoning is NOT_RUN. Cancellation starts on reasoning as
well as visible text. No provider calls, credentials, new dependencies, builds
or device checks were used for FIX1. The external result records the fresh
acceptance commands, tails, regression evidence and remaining minor gaps.

## MR2 FIX2 offline review fixes

The preceding FIX1 section records the first review round.
Chat now validates previous and incoming reasoning-detail text/summary values
and maps unexpected decoder errors to `invalidResponse`, poisoning the turn
instead of leaking runtime exceptions or silently skipping malformed fragments.
FIX2 keeps completed turns when optional usage details are malformed or
inconsistent. Chat `prompt_tokens_details.cached_tokens` and Responses
`input_tokens_details.cached_tokens` are ancillary: malformed values are
ignored instead of invalidating an otherwise completed response. When a cached
count exceeds the corresponding input count, or the input count is unknown,
the cache split is dropped; a valid input count remains unsplit. For valid
input 100, cached input 80 and output 5, both adapters report input 20, cached
input 80, output 5 and total 105. The former rejection expectations were
replaced by regressions for this completed-turn contract.

Decoder timing regressions now take three interleaved samples at N and 2N,
compare the fastest samples, require 2N to stay within 3x N plus 20 ms of
jitter, and require every sample to finish within five seconds. Chat and
Responses use 40,000/80,000 deltas; Anthropic signature accumulation uses
512 KiB/1 MiB. A temporary quadratic concatenation control fails the ratio
check, preserving the regression's ability to detect nonlinear growth while
allowing loaded coverage runners more absolute headroom.

The P0b launcher now obtains keyed-target references only from the local
`~/.config/gitlab-mobile/ai-smoke.json`. Tests cover missing, malformed,
non-object and invalid-UTF-8 configuration, missing targets, non-string and
non-`op://` references, keyless Ollama operation without the file, direct
credential piping, and cleanup when Dart cannot start. Error paths expose
neither a credential reference nor secret bytes. Fresh FIX2 acceptance commands,
output tails and mutation evidence stayed in the local round handoff. A later
round made Chat and Responses ignore a usage object with no usable count, so a
malformed later chunk cannot erase earlier usage.

## AI assistant verification: MR3

MR3 round 0 is commit `22d5aaa530df7d3460c528522e4967ac7620cb45`, based on
`93c164eca8d5498f8d19d38c2d892521a7f727f3`. Round 1 (FIX1) is commit
`2c033a16d335bec9d4582462114925412049ddf1`. Round 2 (FIX2) is commit
`a29a70f35c643ef9f360ca050fc7a4e47d5844ff`. Round 3 (FIX3) is the commit
containing this section (uncommitted during local verification). Pipeline/job
evidence is **NOT_RUN**; no pipeline was queried or triggered.

MR3 adds device-scoped provider settings/keys, account-scoped consent/history
settings, encrypted display-only history, startup recovery and unconditional
account-removal cleanup. FIX1 serializes account mutations across settings and
history, fences cleanup across both owners, invalidates caches and cleans orphan
secure records/keys after successful account loading. Fresh account membership
can reopen a completed cleanup without releasing queued old mutations.

Provider deletion immediately invalidates the provider and persists the reserved
`gitlab-mobile:deleting-provider` preset marker. It revokes account consents,
then deletes the key, then removes the provider. Each successful account write
updates memory; failures resume at initialization/next access. Same-ID recreation
finishes deletion first. A failed initial marker write is only locally pending
until it can be persisted; no durable-marker claim is made on write failure.

History validates root/base/account path types, uses random exclusive temp files,
and requires regular final files. AES-256-GCM binds envelope version, account and
filename in AAD. JSON/crypto and bounded reads/atomic writes run off the UI
isolate. Index metadata includes conversation format version, updatedAt, size
and modification time; unverified old entries are opened before retention or
eviction. Normal saves decrypt only the index plus changed/unindexed/unverified
conversations, preserve conversation-before-index and file-before-index eviction
order, and enforce
512 KiB/50 conversations/16 MiB per account/64 MiB per device limits. Startup
applies 7/30/90-day retention by index metadata. Key unavailable/missing states
preserve data; authenticated unsupported schema remains on disk, skipped with a
notice. Removed-file, repaired-index and unsupported notices remain until UI
acknowledgement; I/O save failure, oversize and capacity eviction are distinct.

On a full iOS restore, both the account list and history key are ThisDeviceOnly:
a successful empty account list authorizes orphan cleanup of restored files.
`keyMissing` describes partial Keychain loss with a surviving account list.
Malformed individual tombstones are skipped and reported, without blocking
valid recovery. This corrects the design's §5.7.6 restore expectation.

FIX2 keeps provider-deletion markers across every provider-list write, removes
orphan provider keys at startup. FIX3 replaces FIX2 peer-controller invalidation
with the plan's single live settings owner per store; a disposed owner retains
ownership until pending writes drain. The shared account mutation queue still
coordinates settings with history. Authenticated unsupported
conversations are quarantined from overwrite, stale-index deletion and eviction;
they count toward capacity and an unsupported index exposes an explicit clear
action. Cleanup leases reopen retained or newly signed-in accounts after completion or cancellation, and fenced writes return a
typed result. Read failures, stale temporary-file removal and later index-write
failures have distinct sticky notices. Malformed account/key inventory entries
and per-account startup failures are isolated and reported. The unused provider
key-length message was removed; all 24 catalogs include the new history recovery
messages. `aiHistoryClearUnsupported` is reserved for MR6's explicit clear action;
its localized message remains in every catalog. FIX3 also protects the entire
account, including its index, from device eviction after any authenticated
unsupported index or conversation is identified; insufficient reclaimable space
returns the explicit storage-limit result. Capacity refusals remain retryable after
space frees; only oversized conversations retain the permanent save-blocking
latch. A successful save after read I/O
failure restores `ready` and clears the read-failure notice. Provider deletion/reset
blocked by a cleaning fence without a tombstone preserves its durable marker
and key and throws typed `cleaning`; startup/next access resumes consent
revocation before completion. Malformed provider-key IDs are individually
skipped, counted and reported during initialization and reset.

FIX1 regression evidence and acceptance commands/counts/output tails follow
inline. Results are local synthetic evidence only; Android emulator, physical
iOS restore, provider/private-project, accessibility, release/store and G0
acceptance are **NOT_RUN**. No real credentials, network calls, devices or new
dependencies were used. Existing login/authenticated-app tests remain unchanged.

The first full-suite attempt passed 3,580 tests and failed two: the unchanged
one-second Anthropic benchmark took 1.466845 seconds, and the unchanged
account-removal test exposed a completed shared-queue future retained across
widget-test zones. A new two-zone regression reproduces the second failure
before the idle tail is released. The repaired queue passes both zones and a
54-test focused run including the entire unchanged authenticated-app and
Anthropic test files. Neither assertions nor timeouts were relaxed. The final
full-suite run below passes both. Before logs distinguish runtime failures from
new-API compilation evidence; documentation and pre-existing-correct behavior
coverage are not assigned invented behavioral failures. All review requests
were accepted; none were rejected. Terminal trailing padding is omitted below.

Historical foreground acceptance outputs and exact command tails are recorded
outside the repository. That MR3 run reported clean pinned Flutter analysis,
current localization generation, 68 Python tests and 3,584 Flutter tests, plus a
clean whitespace check. Those results belong to that source cut and do not
validate subsequent changes. Deliberate mocked Python failure messages did not
represent real credential access or provider requests.

Final full-suite incremental-save measurement: `reads=1 one=0:00:00.002838 conversations26=0:00:00.005589`. Both sizes decrypt only the index during an unchanged small save.

The final full run passes the unchanged decoder performance assertion and protected account-removal tests. The first failure is retained as evidence, not silently discarded; the benchmark was not modified and its host-load sensitivity remains visible in the earlier run.

## MR4 — read-only tools and bounded runner

Commit `77f2be5` adds the project-bound read port, ten-tool catalogue,
shared sensitive-path policy, SHA-pinned context builders, untrusted-data prompt
labels, live secrets, interface checks and the bounded conversation runner.
`AiRunnerBinding` observes the existing settings/session owners. The gate is
still false and this slice adds no UI, account write path or dependency.

Evidence vocabulary: the new tests are **synthetic**, using in-memory settings,
`FakeAdapter` / `WorkspaceFixture`, synthetic OAuth rotation and recorded SSE
fixtures. **RECORDED** means decoding the retained P0a fixture and replaying its
provider object through the real encoder; it is not a fresh provider call.
The submitted MR4 base is commit `77f2be5`; the first review fixes are in commit
`cdbfc63`. This section cites only repository source, tests and retained
sanitized fixtures. Reversible mutation checks, acceptance commands, CI
pipelines/jobs and live provider checks are **NOT_RUN** for this ledger.

Round-two regressions are retained in `test/ai/fix2_plain_text_test.dart`:
plain values survive JSON/XML encoding boundaries for late re-redaction,
provider-readable strings (including citation display fields) are checked
without decoding wire escapes, deeply
nested literal escapes remain resumable, summaries escape once across repeated
segments, and streaming snapshots include prior tool-round text.
`test/ai/ai_tools_test.dart` protects `executeResult` metadata and its retained
plain values; `test/ai/ai_live_smoke_test.dart` rejects older closing markers.
`tool/tests/test_ai_runner_contract.py` requires explicit active cancellation and
keeps this ledger limited to repository evidence or **NOT_RUN**.

Round three was committed as `5a1e4d1`, round four as `d199a3f` and round five
as `5671be5`.
`AiAppText` caches each immutable encoded view and retains only the deliverable
plain prefix. Private cut markers travel with retained strings through JSON-key
collisions, nested clips and readable projection composition. Every later
redaction trims the longest trailing proper prefix of a currently known secret
or its cached pattern-only alias from each cut string. Exact alias matching also
removes a retained key remainder whose head was pattern-redacted before the key
became known. There is no retained margin. JSON traversal stops retaining entries
after the cut, and projection and tool-result cuts use the same model. Whole
fetched sources are still redacted before any retention cut.

`test/ai/fix5_regressions_test.dart` contains the production catalogue/runner
inputs for colliding `title`/`description` keys across two secret refreshes,
undelivered clipped provenance summarized before a late-secret refresh, and
dot/base64-shaped keys learned after intake with and without catalogue clipping.
Each production input covers all three wire formats. Additional synthetic tests
cover a colliding cut value and existing context/prior-summary cut markers.
These are repository evidence only; external execution receipts, mutations,
CI, live providers, private integration, devices and AOT remain **NOT_RUN** for
this ledger.

Round six adds cached pattern aliases to frozen-text verification when at least
four secret characters remain outside replacement markers. A newly known alias
already sent stops the send with `newSecret`; the follow-up uses a re-redacted
projection. Aliases containing only replacement markers are excluded from the
cache, preserving zero redaction counts for existing markers. Round seven
applies the same four-character minimum when caching, so an alias with a one to
three character remainder (a pasted key with one trailing space) no longer
over-matches text beside markers in intake or cut-end trimming. Alias cut-end
trimming requires a match beyond its leading marker into the secret remainder.
`test/ai/fix6_regressions_test.dart` covers the production catalogue timing after
payload two, full-secret behavior, the three/four-character verification boundary,
zero marker counts and runner late-redaction counts in all three wire formats,
and preservation of a complete marker while partial alias remainders still trim.
Nested known-secret aliases retain the documented residual below.

A secret already delivered before it became known remains a residual. A pattern
starting before the secret and ending inside it can produce a different alias
layout; a late secret that contains a previously known secret is split by that
secret's replacement and, with or without a cut, is not covered by its alias
(R5-NEST). Those two residuals are not repaired here. Runner answer clips at
64,000 characters and history codec truncations at
16,000/64,000 characters and 8 KiB have no cut markers and can reach
`restoreFromDisplay` projections. They currently contain provider-produced or
already-sent text; MR5/MR6 must re-evaluate restoring them to a different recipient.

The round-three tests in `test/ai/fix2_plain_text_test.dart` place newly learned
secrets at the final tool-tail refresh, recheck frozen issue/job-log results on a
follow-up, exercise oversized tool-tail clipping and enforce escaped-width
projection budgets. Legacy plain-text constructors are test-only and reject
`<gitlab_data` anywhere in their input. `AiToolResult.copyWith` accepts only
structured `data`, and the constructor tests plus Python production-call
boundary guard protect those entry points. Production tools return data-aware
`executeResult` values. The renamed FIX1 test explicitly checks
that the redacted marker survives repeated escaping. The offline closing-smoke
test requires the exact complete final-answer note and rejects a bare marker.
These are repository source and synthetic-test evidence only. Mutation and
performance probes, acceptance command receipts, CI pipelines/jobs, live
providers, private GitLab integration, devices and AOT checks remain
**NOT_RUN** for this ledger.

| Contract | Current evidence |
| --- | --- |
| Scope, provenance, schemas, GET/HEAD-only adapter, field projection, sensitive read/diff/search, newest notes, full SHA and HTTP/search/output budgets | `test/ai/ai_tools_test.dart`, context tests, Python boundary guard; synthetic |
| Prefix replay across runs, newly saved keys and provider-readable output, OAuth refresh during tool reads, key-only rollover | `runner_test.dart`, `runner_lifecycle_test.dart`; synthetic |
| Six model calls, four tools per batch, twelve per send, bounded UTF-16 output, fresh budgets including exhausted-read finishing, soft timeout with one pending source read | runner/catalogue tests; synthetic |
| Tools retained in all three closing formats; safe result metadata and every synthetic terminal result reach display callbacks; empty final answer | runner and offline live-smoke tests; synthetic |
| Context once, budgeted/escaped/nonce-labelled projection, first-call tail restoration, finishing on truncation, final note redaction | runner tests; synthetic |
| Every stream/await/send checkpoint; consent, recipient revision, session generation and exact API ownership; active-request cancellation keeps the transport reusable after stop/timeout | runner/lifecycle tests using the production binding; synthetic |
| Actual vs estimated input usage, throttled cumulative redacted display snapshots, partial interrupted output recovered within the tool deadline but excluded from replay, provider-byte replay | runner tests plus MR2 wire/recorded suites; synthetic / RECORDED |
| Link-local enumeration and unknown/missing interface confirmation | network and runner tests; synthetic |
| Live runner matrix (`runner-tool-loop`, `runner-closing-call`) | Harness extended; authenticated P0b **NOT_RUN** |

Earlier-MR requirements remain binding: strip ANSI before source redaction;
redact complete fetched text before truncation and reject inputs over 2 MiB;
redact running traces accumulated from offset zero with `redactSource`; use
`redactFragment` on line-aligned excerpts; block sensitive diff paths; preserve
the first private-key withholding notice. MR2 binding detection, server-tool
input accumulation, empty-Anthropic-array rejection and recorded replay tests
are covered by focused regressions. This checkout needed small packet-required
repairs: nested OpenRouter `metadata.raw` binding classification, accumulation of
Anthropic `server_tool_use` input deltas, and atomic rejection of empty
Anthropic replay content (a legal empty text/thinking answer still works).
MR3's consent-store validity and single settings owner
are used directly; access/refresh values are reread after OAuth rotation.

P0b (all authenticated provider checks), fresh native-provider conformance,
private-project integration, Android/iOS, accessibility and AOT redaction timing
are **NOT_RUN**. MR5/MR6 UI, MR7 gate/platform/device acceptance and plan Appendix
D live calls are deferred to their prescribed lanes. None of the offline
results upgrades P0a, provider support or G0 acceptance.


## MR5 — settings and consent, gate off (2026-10-21)

The AI setup UI is available through explicit controller injection in synthetic
widget tests. Only `main.dart` reads `MERGELINE_AI_ASSISTANT`; its default remains
false. An omitted AI bundle preserves the existing shell tree. The app-level,
non-autoDispose settings owner survives account changes, while `AiScope` carries
the active account identity.

The Me row opens the grouped settings page. Provider edits preserve the persisted
default order. Deletion confirms key and all-account consent removal. The editor
validates endpoints and key whitespace before storage, offers keyless local and
custom presets, lists models through an injectable wire client, and distinguishes
OpenRouter catalogue access from key verification. Model reads do not require an
already-selected model and discard stale results. The output limit is persisted
in caps and used by the runner, with a 4096-token default for older records and an explicit 512–65,536 range.

Consent displays the versioned recipient contract, model-sensitive data use,
retention, policy and irreversible-disclosure warning. It persists a readable
summary and hash; recorded details remain readable after configuration changes.
Provider/account changes while the dialog is open invalidate acceptance. Consent writes recheck the captured recipient revision inside the settings queue; post-write cleanup conditionally removes only that exact grant. History
controls use the coordinator, preserve unavailable/missing-key data, and offer
explicit cleanup/retry. History-only clearing preserves consents and preferences,
disables persistence before deleting files and deletes the key last.

New synthetic suites are `ai_injection_test.dart`,
`ai_provider_editor_test.dart`, `ai_consent_dialog_test.dart`,
`ai_settings_page_test.dart`, `ai_settings_history_states_test.dart`,
`ai_consent_race_test.dart` and `ai_output_limit_test.dart` under
`test/ai/`. They cover injection, account switching, incoming links, key/endpoint
validation, model listing, consent invalidation/revocation, persistence controls
and 320 dp / 2x text / Arabic RTL / dark layouts. All 24 catalogs contain the new
UI messages. Existing tests and their expectations remain unchanged.

The foreground acceptance receipt, complete command outputs/tails and any gaps
are recorded outside the repository. There is
no MR5 commit or pipeline: the task forbids committing and pushing. Live provider
calls, real keys, internet, Android/iOS devices, emulator checks and rendered
screenshot review are **NOT_RUN**. Provider verification labels remain unverified;
no catalogue/key probe or synthetic test upgrades the P0b conformance ledger,
provider support, G0 acceptance or release readiness. MR6 chat/entry points and
MR7 gate/native/device work remain outside this MR.

### MR5 FIX1 follow-up

The follow-up derives consent from the current provider and bundled per-model
policy table, with structured policy URL, retention and check-date fields.
Caller-provided policy text cannot change the disclosure or granted hash.
Training disclosures include retention; the dialog blocks Back while saving,
uses locale date/time formatting, and keeps the organization notice in a card
with body content. Additional behavioral regressions exercise production
model swaps, unknown policies, forged disclosures and Arabic RTL layout.

Foreground acceptance and mutation evidence are recorded outside this repository
in the owner-supplied follow-up receipt. No commit, push,
provider call, real key, internet, native build or device evidence is authorized
for this follow-up; the gate remains false.


### MR5 FIX2 logic follow-up

Policy inheritance now requires the normalized scheme, host, port and base path
of the preset endpoint for the selected format. Other recipients use unknown
policy with no inherited link or retention. Non-model-sensitive preset contracts
include the configured data-policy URL without inferring training or retention.
The existing disclosure renderer already displays arbitrary stated retention days;
a new regression protects the no-training/seven-day case.

`aiToolCatalogueVersion` and `aiDisclosureVersion` are the current version source.
Settings can call `AiConsentContract aiCurrentConsentContractFor(AiProviderConfig
provider)`. The dialog derives recipient/policy from the provider while retaining
the requested versions and categories, and refuses a differing requested hash.
Invalid legacy endpoints fail initialization as malformed before provider
publication, allowing the existing reset action and avoiding invalid consent-row
inputs; settings wiring remains owned by the orchestrator.

Pending history-clear markers are checked at enable/save boundaries and included
in secure inventory and orphan cleanup. Keyless saves delete credentials before
publishing configuration and restore the prior credential/binding on failure.
Legacy key replacement uses the coordinated save path, and reset invalidates its
key cache immediately after durable deletion. Startup deletes mismatched bound
credentials instead of leaving stored secrets outside the redaction set.

The new synthetic regressions are in `test/ai/fix2_logic_test.dart`. The FIX2b
follow-up migrates seven consent fixtures to derived current contracts, retains
their dialog, race and layout checks, and asserts refusal of forged policy before
showing a valid provider-derived disclosure. Foreground acceptance results, exact
failures and six reversible mutation receipts are recorded outside the repository.
This follow-up has no commit,
push, pipeline/job, internet, provider call, real key, build or device evidence;
the feature gate remains false. These checks do not establish G0 acceptance.

### MR5 review rounds 3–9 and emulator checks

This supersedes the "no MR5 commit or pipeline … emulator checks NOT_RUN" note
above, which described the first implementation packet. The branch's CI
evidence is the merge request pipeline linked from the MR; nothing here infers
a pipeline result.

Fixes after round 2, each with a synthetic regression (the mutation runs that
revert a fix and see its test fail are recorded outside the repository):

- The unsaved key draft is bound to its recipient (origin, base path, auth
  header) and is dropped with a notice when a format, URL or preset change
  alters it; the key status line follows the draft as it is typed.
- The editor's policy line uses the same derivation as the consent dialog, so
  it never states more than the contract (unknown for other recipients and
  unlisted formats). Azure resource endpoints match one DNS label under the
  fixed suffix, path and default port.
- An unedited preset model list URL follows the base URL's server (cleared on
  another server, restored on the preset's); an edited one is kept. Listeners
  act only on text changes, so a tap or selection is not an edit and does not
  drop a loaded model list or the "key verified" notice.
- An error caused only by the model list URL is shown on that field, with a
  pointer under the base URL. A blocked save, model read or key check opens the
  advanced section and scrolls to the failing field (also the limit fields and
  empty required fields, the topmost one first) once the opening animation has
  had its time and the scroll extent is stable. Only a field whose error is
  shown and whose value is still wrong is a target: an error fixed while
  waiting is dropped, and the reveal moves on to another shown error that is
  still wrong, or stops if there is none.
- A failed keyless save restores a key that was only in the live cache, without
  recreating its absent durable slot. A port too large for an int is an invalid
  draft, not an exception.
- Two new messages in 24 languages; Arabic isolates the literal `/models`, and
  `tool/l10n.py` writes bidirectional controls as `\u` escapes.

Emulator checks (Android API 36 emulator, gate-on debug builds of `080c7fb`,
`77da6cd`, `aa1ed97`, `b0a1c66` with the temporary log below, and `c6b2824`;
synthetic keys only, no provider request sent, signed-in account used
read-only):
preset descriptions wrap; the policy line follows format and recipient; the key
draft is cleared on a recipient change; the model list URL clears and returns
with the base URL and an edited one keeps its value with its own error; the
advanced section's first label is not clipped; a blocked save scrolls to the
model list URL and limit errors, with and without the keyboard. The scroll
timing fault was found only on the emulator: the first two frames after opening
still had a scroll extent of 0. A temporary log (not committed) showed extent
0, 0, 81 … 584, 584 and then a scroll to 352 after the fix; the widget-test clock
does not reproduce that first-frame timing for the model list URL case, while
the limit case at 412 × 915 does. The key status line fix (`fecf2ae`) came from
the `c6b2824` walkthrough; the later reveal refinements (`9e758f1` onward:
required fields, current-value checks, target choice) have synthetic evidence
only.

Live provider calls, real keys, physical devices, iOS and the preset policy
URLs' current content remain **NOT_RUN**. The feature gate remains false; none
of this establishes G0 acceptance or provider conformance.

## MR6a-1 — chat page and entry points, gate off (2026-10-21)

This MR adds the chat behind the same `MERGELINE_AI_ASSISTANT` gate, which
still defaults to false. It contains:

- the session contract (`AiChatSession`, `AiRunRegistry`, at most three running
  conversations per account);
- the controller, which owns one runner per conversation, pins context per
  origin and coalesces stream updates;
- the chat page;
- entry points: the app-bar icon on a failed job, a menu item on other jobs,
  "AI summary" and "Discuss with AI" on merge requests, "Discuss with AI" on
  issues, and "Explain this file with AI" on a text file at a pinned commit.

Replies render as offline Markdown: no image, SVG, media or upload is fetched,
and links ask before opening. Long replies are split into segments. Context
chips, notices, tool rows and run endings are display-only; nothing in the
display list is replayed to the provider.

Synthetic suites:
- `test/ai/ai_chat_page_test.dart`, `ai_chat_controller_test.dart`,
  `ai_chat_context_test.dart`, `ai_run_registry_test.dart`,
  `ai_entry_points_test.dart` and `ai_notice_codec_test.dart`;
- `test/markdown_offline_test.dart`;
- an added runner regression for the arguments a started tool row shows.

Emulator run (Android API 36 emulator; gate-on debug builds of `91b4369`, then
`c28dd21`. The builds were made from these changes before the branch was
rebased onto main; commits are cited by their rebased SHAs):
- Real provider: OpenCode Go, Chat Completions, model `glm-5.3-flash`. The key
  went through stdin into the emulator field; it is not in the repository,
  logs or this ledger.
- The signed-in GitLab account was used read-only.
- Only content of this public project was sent: its README and `.fvmrc`, one
  failed job log, merge request !44, and the files the model read with tools.

Observed on `91b4369`:
- The consent card blocks sending until agreed.
- Replies stream, render Markdown, and "Copy all" works.
- Stop marks the partial reply as interrupted and not kept, plus a stopped
  notice.
- Leaving the page mid-reply and reopening it returns the same conversation,
  with the reply finished in the background.
- The failed-job entry sends the job log with an "8 secrets were redacted"
  notice.
- "AI summary" sends once when the session is ready.
- With read-only tools enabled (after a new consent), tool rows appear.

The same run found these defects, fixed in `c28dd21` with synthetic
regressions; the mutation runs are recorded outside the repository:
- The answer was listed above the tool rows it used. Tool rows are now
  inserted before the run's answer, which stays last, so text written before
  a tool call also reads below the reads.
- Tool rows did not say what they read. The runner now hands the progress row
  the redacted top-level scalar arguments; long or nested values are left out,
  never cut. The row shows a short target with controls removed: a path,
  `#iid`, `!iid` or a short SHA.
- Context chips showed the internal source tag (`file`, `job`). They now name
  the page: file name, `!iid`, `#iid` or job name. The tag sent to the model is
  unchanged.
- Nothing showed while the page context loaded (about 20 s for a merge
  request). A progress row now shows.
- The app's update snack bar covered the composer. The chat now has its own
  `ScaffoldMessenger`.
- The consent dialog opened from the chat said "Agree and send" with nothing
  to send. It now says "Agree".
- Also: an "Open AI settings" menu item; "Thinking…" under an empty streaming
  reply; spacing below the read-only tools switch.

Re-run on `c28dd21`:
- the progress row shows;
- the composer stays clear of the update snack bar;
- chips read `.fvmrc · 118 characters` and `!44 · 4744 characters`;
- tool rows read, for example, `Read file · pubspec.yaml` and
  `Read merge request · !44`, above the answer;
- the menu opens AI settings.

After the run, deleting the provider (key and consents) turned the open chat
into the "Add an AI provider first" blocker. The account was then removed from
the emulator.

**NOT_RUN** on a device: the too-many-running blocker, the cleartext
confirmation, the failure card, very long reply splitting, the new-conversation
offer, Arabic and other right-to-left layouts, dark mode, iOS, physical
devices, and the Responses and Anthropic formats against a live provider.
These have synthetic evidence only. Saved chat history is not part of this MR.

Known and left for separate work:
- The bundled code font drew ligatures, so `>=` read as `≥` in code spans,
  file views and diffs app-wide. Fixed since by !95, which this branch is
  rebased onto.
- The update snack bar can still cover bottom inputs on other pages.

The feature gate remains false; none of this establishes G0 acceptance or
provider conformance.

### MR6a-1 review round 1 and the second emulator run

Codex GPT-6.1-Sol and Opus 5.5 both returned REQUEST CHANGES. DeepSeek V4.1 Flash returned APPROVE WITH MINOR FIXES; agy Argon and cursor Grok were out of quota. The fixes, each with a synthetic regression (mutation runs are recorded outside the repository):

**Display safety**
- Tool-row targets and the runner's display arguments strip control characters before redacting, so a zero-width character inside a secret cannot restore it. Argument keys must be simple identifiers.
- The title goes through `displaySafe`. Model-chosen tool names outside the catalogue show a generic label.

**Entry points and session lifecycle**
- "AI summary" is a parameter of the visit, not of the kept session.
- Closing the page releases an idle session that holds nothing, so the next visit reads the page again.
- The file entry needs a full commit SHA and no sensitive path.

**Failures and capacity**
- GitLab reads that fail keep their `ApiFailure` and are shown with the app's failure notice: account, instance and page, an ambiguous 404, retry and account switch.
- A full account (three running) shows its blocker while idle. The registry notifies idle sessions whenever capacity changes.

**Context sent**
- Issues without repository access are still sent, without a pinned SHA.
- Merge requests include the newest 20 non-system notes, and every note says whether it is internal.
- "What was sent" shows the full redacted text with its size and pinned SHA.

**Conversation behaviour**
- A provider settings change keeps the conversation and adds a "new conversation" notice.
- Reads that never ran show as skipped, and notices raised during a run go before the answer, so the answer stays last.
- A stopped or failed start keeps the user's message with a "not sent" notice.
- Sending, or a newly shown blocker, scrolls to the newest content.

**Wording and other**
- The empty chat explains in two sentences what the AI reads.
- Redaction notices use each language's reviewed word for "secret".
- Arabic counts read correctly for any number.
- The AI User-Agent carries the app version from `pubspec.yaml`, checked by a tool test.

Second emulator run on the gate-on debug build of `2b01b96` (same provider, model and key handling as above; this public project only):
- A discussion visit to merge request !44 was left without sending. A later "AI summary" visit sent the summary once after consent.
- The consent dialog opened from the chat says "Agree".
- The blocker card sits at the top of an empty chat and above the composer in a conversation, and scrolls into view.
- The context chip reads `!44 · 4755 characters`. The tool rows read `Read merge request · !44`, `Read merge request changes` and `Search project · attachmentDownloadFileName`, above the answer.
- "What was sent" shows the full sent text with `Pinned at a0b27731`.
- Turning the provider's read-only tools off from the chat menu's AI settings asked for consent again, kept the conversation, and showed the new-conversation notice.
- In Arabic, the tool rows, chip and notice are right to left. The English reply stays left to right, and the character counts read `عدد الأحرف: N`.
- The provider was deleted and the account removed afterwards. This run supersedes the Arabic item in the MR6a-1 NOT_RUN list above.

Still **NOT_RUN** on a device:
- the too-many-running blocker, the cleartext confirmation and very long reply splitting;
- dark mode, iOS, physical devices, and the Responses and Anthropic formats against a live provider.

The registry is still created lazily in `build`. It is memoised and keyed by account generation; this is an intended non-change.

### MR6a-1 review round 2

Codex returned REQUEST CHANGES and Opus APPROVE WITH MINOR FIXES on the round-1 fixes. Fixed, each with a regression test and a mutation run recorded outside the repository:

**Display and lifecycle**
- `recheck` learns the live secrets before any blocker, so the title is redacted while settings or consent are pending.
- The display is re-redacted only when the secret set has grown; the "What was sent" preview is cut from the already redacted text.
- The registry counts open pages per session and releases only after the last one closes.
- A summary visit to a conversation that already has messages puts the request in the composer.

**Context sent**
- Issue and merge request notes are read page by page, at most five pages, until 20 are not system notes.
- Context too large to scan for secrets is `tooLarge`.

**Smaller fixes**
- A message stopped before sending keeps no "What was sent" chips.
- The empty chat's list scrolls a new card into view.
- Errors raised by the AI path stay `AiFailure`.

Left for later, by choice:
- When reading merge request or issue notes fails, the whole context still fails. A later change can send without notes and say so.
- After a settings change, the new conversation reuses the context read when the page first opened. The chip shows the pinned SHA.

### MR6a-1 review round 3

Codex returned REQUEST CHANGES and Opus APPROVE WITH MINOR FIXES. Fixed, each with a regression test and a mutation run recorded outside the repository:
- **Display redaction failures.** The display pass records its secret-set revision only after every item passed. A pass that fails, for example when the redactor refuses a secret inside its own marker, blocks the conversation and is tried again rather than skipped.
- **Learning secrets while blocked.** `recheck` redoes the display pass right after learning the secrets, so the conversation follows a larger secret set in every state, not only when ready.
- **Chip placement.** "What was sent" chips stay on the message whose request delivered the page context. A first request that failed (or a refused cleartext send) drops its chips, and the next message carries them; chips for blocked paths always stay.
- **Shared pages.** The page that sends sets the cleartext confirmation, so a second page on the same session that closed earlier cannot leave it cleared.
- **Notes across pages.** Notes read across pages are de-duplicated by id.
- **Other.**
  - Sending needs a loaded context.
  - Registry disposal clears its page counts.

### MR6a-1 review round 4

Codex and Opus returned REQUEST CHANGES. Fixed, each with a regression test and a mutation run recorded outside the repository:

**Chip placement (supersedes the round-3 note on chip placement)**
- The runner now reports the redacted context blocks it attached to the run's user message (`AiRunner.sentContext`). After every run the controller makes that message's chips say exactly what its request carried:
  - the page context;
  - a conversation summary after a new segment, labelled as such;
  - nothing.
- Chips are removed only when nothing left the device (`modelCalls == 0`, or a failure before the run). A request that was sent and then stopped, timed out or failed keeps its chips.
- Blocked-path chips always stay.

**Display redaction**
- A display pass hides any item it cannot check against the new secrets: a reply becomes hidden, a message becomes a redaction notice, and a tool row loses its excerpt.
- After a failure the pass blocks and is tried again on the next recheck.

One new message, "Conversation summary", is translated in all 24 catalogs.

**Follow-up in the same round (Opus R4-3, N4-1, N4-2)**
- `displaySafe` no longer throws. The page builds its title with it, so a known secret that makes every redaction fail (one inside the `[REDACTED]` marker) left the page as an error box with no blocker card. It now returns an empty string for text it cannot check, and the page shows the block.
- A display pass that fails while a message is being sent now blocks the chat with `contextUnavailable`, as it does in a recheck. Before, the chat stayed ready and each retry added another unsent message.
- A message stopped before sending keeps its blocked-path chips.

Tests: one widget test with the real controller, plus two controller tests. Removing each fix turns its test red.

### MR6a-1 review round 5

Codex and Opus returned REQUEST CHANGES. Both found the same main problem. Fixed:

- **Chips could show a secret learned during the run (Codex P1, Opus R5-1).**
  - Cause: after the run, `_settleChips` rebuilt the chips from the runner's blocks without redacting them again, and the display pass had already moved past that secret.
  - Fix: the runner reports the blocks as last redacted before sending (`_redactTail`). The controller redacts the settled message again with the live secrets, and hides the message if that fails.
  - Test: one test learns the secret at each refresh of a send in turn. A runner test checks that `sentContext` contains a secret exactly when the request did.
- **A request the transport refused locally counted as sent (Codex P2).**
  - `AiFailure.notSent` marks a refusal before the request reaches the network: a remembered Retry-After, a closed transport, a blocked endpoint, or an oversized body.
  - The runner does not count those calls, so such a message has no chips.
- **A list of notices alone cleared the block (Codex P2).** A display pass now first checks that redaction works at all.
- **Steps after the run threw into the catch meant for steps before it (Opus R5-2).**
  - The display pass after the run no longer throws there.
  - When it fails, the reply is hidden too, and the chat blocks with the run's own outcome kept.
- **The branch for "nothing was sent" had no test (Opus R5-3).** It now has one: a first request too long to send. The round-4 entry said every fix had a mutation run; that was not true for this branch.
- **Nits:**
  - A title that cannot be checked falls back to the assistant label (N5-5).
  - The summary-chip test now asserts the single chip (N5-2).
  - A new test covers a pass that fails for only some items (N5-3).
  - The display pass during a run repaints even when it fails, and no longer swaps in the page chips (N5-7, N5-8).

**Mutation runs, outside the repository.** Each of these 9 changes makes the named test fail:
- settle without the re-redaction: "chips never show a secret learned during the send";
- `_redactTail` without updating `sentContext`: "sentContext is the context as last redacted before sending";
- not discounting a refused call: "a request refused before sending takes its chips back";
- the transport without `notSent`: that test and "429 with Retry-After populates the shared registry";
- no redaction probe: "a list of notices alone does not clear the block";
- chips kept when nothing was sent: "a first request too long to send takes its chips back";
- the display pass after the run unwrapped, and the reply shown after a failed pass: "a display pass that fails during the run keeps its outcome";
- an empty title: "a title that cannot be checked falls back to the assistant".

**Deferred:**
- N5-4: a hidden message also loses its chip.
- N5-6: a run's own failure stays under the block card until the next recheck clears it.

### MR6a-1 review round 6

Codex returned REQUEST CHANGES; Opus returned APPROVE WITH MINOR FIXES. Fixed:

- **A secret with `&`, `<` or `>` learned after sending showed escaped in "What was sent" (Codex P1, Opus R6-1).**
  - Cause: redaction ran on the encoded text, where `&` is `&amp;`, so the secret no longer matched.
  - Fix: a chip keeps its redacted block in memory (`AiContextChip.block`, never saved). Settling and every later display pass redact the block's plain text first, then encode it again, and cut the preview from the result.
  - Tests: the late-secret test now also uses a secret with `&<>` and checks both the plain and the escaped forms. A new test covers a secret learned after the run is over.
- **A request refused locally still used token budget (Codex P2, Opus R6-2).** The runner skips usage for a `notSent` failure. Test: three refused runs leave both token counters at 0.
- **A failed settle left the display-failure flag set for good (Opus R6-3).** It now resets the display revision so that the next pass computes the flag again, and a cleared conversation drops the flag.
  - No test reaches this path end to end. The trigger is a collision that only the settled chips have, such as a summary chip after a new segment.
  - Opus reproduced the old effect by fault injection in a copy.
- **Nits:**
  - The transport comment now covers only the refusals it marks (N6-2).
  - The round-5 mutation list above is corrected (N6-3).

**Mutation runs, outside the repository:**
- Skipping the block path fails "chips never show a secret learned during the send" and "a secret learned after the run is redacted in its chips".
- Recording usage for refused calls fails "a request refused before sending uses no token budget".

**Still open:**
- N6-4: the run-outcome test cannot tell its outcome apart from the catch path.
  - Its `lastEnd` assertion records N6-6's current result. It does not detect removing the wrap around the display pass after the run (Opus N7-1).
  - A test that tells them apart needs a run that ends `done` and a pass after it that fails. Under N6-6 that only happens when settle fails too.
  - The stoppedBySettings variant is not written.
- N6-5: a title that cannot be checked also drops the app's own `!iid`.
- N6-6 (existing behaviour): a failed display pass inside a run ends the run as failed.

### MR6a-1 review round 7

Codex and Opus returned APPROVE WITH MINOR FIXES; neither found a blocker. Applied:

- **Chip size (Opus N7-3).** A chip keeps the size that was sent when a later pass redacts more. The chip test checks the size against the request.
- **Budget tests (Codex P3).**
  - A failure that may have been sent still counts.
  - A refused request after a sent one leaves only the sent one in the budget.
- **Formatting (Opus N7-7).** The lines this MR touched now match `dart format`.

Behaviour recorded as it is (Opus N7-2):
- When settling fails in the normal path, the message becomes a redaction notice. The display pass right after it then succeeds, so the chat is not blocked and the reply shows.
- The reply was redacted in the runner with the same secrets, so nothing unchecked is shown.
- After a stop or a failure before the run, the chat stays blocked until the next recheck.
- Neither path has a test; the trigger needs a collision that only the settled chips have.

**Still open, for MR6b:**
- Restoring saved history (Opus N7-4). A saved preview is cut from encoded text. A restored chip has no block, so a secret with `&`, `<` or `>` learned after saving would show escaped in a restored preview.
  - Before history is restored, either cut previews from the plain text when saving, or match the escaped forms when redacting.
- A summary chip carries the page's pinned commit (N7-5, existing behaviour).

The emulator run on `109596d` (round 5) covers the visible chip behaviour:
- the chip stays on a sent message after the reply;
- "What was sent" shows the exact `<gitlab_data>` block, its size and its pinned commit;
- a follow-up message carries no chip.

Rounds 6 and 7 changed redaction internals, sizes and budget accounting only.

### MR6a-2: append an answer to an ordinary comment draft

A completed, display-safe Work Item answer offers **Append to comment draft**.
It opens the same account/resource-scoped encrypted draft used by the discussion
tab. Existing Markdown and whitespace remain intact; the answer follows two
newlines. Opening or leaving this editor sends no GitLab mutation. Sending still
requires reviewing the text and pressing Save.

The action captures the account, API, resource and session generation. Missing
session ownership or a later generation change prevents insertion. A failed or
unrecognized secure-draft read blocks replacement. Comment saves persist an
attempt marker before dispatch: an interrupted or cancelled write stays blocked
after reopening, while an acknowledged write consumes only its exact submitted
draft, without refreshing a different owner.

Regressions live in `test/ai_comment_draft_test.dart`,
`test/ai/ai_entry_points_test.dart`, `test/ai/ai_chat_page_test.dart` and
`test/editor_uncertain_save_test.dart`. The synthetic Android target is:

```sh
flutter run --flavor gitlab -d emulator-5600 \
  -t tool/emulator_ai_comment.dart \
  --dart-define=EMULATOR_UI_QA=true \
  --dart-define=MERGELINE_AI_ASSISTANT=true
```

It displays a persistent synthetic banner, uses memory-only account/draft data,
preloads an existing draft and counts fixture writes. The write count must stay
zero through insertion and leaving. Production AI remains disabled by default.
Synthetic tests and emulator checks do not establish real-provider/private-project
integration, iOS acceptance, publication or G0 acceptance. Exact-source test,
build and pipeline receipts belong to the submitting MR.

The `ea67553` source passed 5,046 Flutter tests (zero failures/skips) and full
analysis. On the project-owned API 36 emulator, the completed answer appended to
the existing MR draft, survived leaving and reopening the ordinary editor, and
kept the fixture write count at zero. Explicit Save closed the editor, raised the
count to one, and displayed the combined body in the refreshed discussion. The
original APK was restored with `install -r`; installed bytes matched its saved
SHA-256. Public package metadata, exact-source evidence and scope limits are in
[`receipts/2026-10-22-ai-comment-qa.json`](receipts/2026-10-22-ai-comment-qa.json).

Delivery status is recorded by
[MR !98](https://gitlab.com/aa22396584/gitlab-mobile/-/merge_requests/98), whose
exact-head required jobs gate the merge. This local evidence does not claim CI
success. Android is the current validation priority. iOS validation is deferred
for this merge decision and remains an open product-acceptance lane; the deferral
is not iOS evidence.

### MR6a-3: preview before an answer joins a comment draft

!98 appended the display-safe answer to the comment draft as written. The plan
(v5 §6.6) also requires the answer to be made safe for GitLab first and shown in a
preview. `neutralizeForGitLabDraft` existed with tests but had no caller. This
MR closes that gap:

- **Quick actions.** GitLab runs a line whose first character is `/` (after it
  deletes `\r`) when a comment is posted, and the editor field has quick actions
  on. The answer now goes through `neutralizeForGitLabDraft` before anything
  else, and the result is checked again after the preview. The preview reports
  how many lines changed (`quickActionLineCount`).
- **Mentions.** `analyzeDraftMentions` (`lib/core/ai/draft_mentions.dart`) wraps
  each `@name` candidate in a code span, from last to first, and keeps a wrap only
  when reparsing with `package:markdown` 7.3.1 shows the code-text multiset grew
  by exactly that token and one fewer mention is outside code. The candidate
  pattern is a superset of GitLab's (`@all`, groups, `-@`, `.@`, `+@`); emails
  are excluded. A mention it cannot neutralize (an HTML block, an adjacent or
  unpaired backtick, more than 50 candidates) is listed, and the append stays
  disabled until the user ticks "I understand that posting notifies these
  users". "Keep mention notifications" appends the text unchanged.
- **References.** `#12`, `!34`, `group/project#12` and issue, merge request or
  work item URLs outside code are counted, because posting adds a mention note
  to each.
- **Sources and confidentiality.** The preview lists what the answer drew on:
  the context sent with its question and the tools that turn ran. Tool results
  now carry `readConfidential` when `get_issue` or an issue search returned an
  issue with `confidential: true`. The flag is display-only: provider request
  bodies are byte-identical either way (tested for all three formats). The
  history codec stores `confidential: true` only when set, so older records are
  unchanged. If any earlier read in the conversation was confidential and the
  target is not a confidential issue, the preview warns before appending.
- Nothing is posted from the preview. The append still opens the ordinary
  editor, and posting still needs Save.

Synthetic suites:
- `test/ai/draft_mentions_test.dart`. Its generated strings check the
  analyzer's self-consistency against `package:markdown` 7.3.1 only. The oracle
  is the same parser, so they do not show agreement with GitLab's renderer,
  which stays `NOT_VERIFIED`.
- `test/ai/ai_confidential_read_test.dart`.
- Added cases in `test/ai/ai_chat_controller_test.dart` and
  `test/ai/quick_actions_test.dart`.
- The append-preview group in `test/ai/ai_chat_page_test.dart`: quick actions,
  mentions, acknowledgement, references, sources, the confidential warning,
  cancel, a conversation that changed while the sheet was open, and 320 dp at
  2x text in zh-TW and Arabic plus 640×360 landscape in English.
- The two entry-point tests, which now confirm the preview first.

Each of five guards in the insert flow was removed in turn, and each removal
turned its test red: neutralization, mention handling, the acknowledgement
gate, the target's own confidentiality, and the re-check after the sheet. The
re-check was removed as a whole block. Review round 1 found that removing only
its `contains(item)` condition went unnoticed; see below.

The synthetic emulator target `tool/emulator_ai_comment.dart` now answers with a
quick-action line, a mention and a reference after a confidential read, so one
run shows every part of the preview.

Two related fixes found on the emulator:

- **Line breaks.** !98 passed the answer through the session's `displaySafe`,
  which removes every control character, including line feeds, so an appended
  answer arrived as one line and lost its paragraphs, lists and code. The draft
  path now uses `draftSafe`: the same redaction and hidden-character removal,
  keeping tabs and line breaks. The test fakes had kept newlines, so no test
  saw it. The fake session now strips them from display text as the controller
  does, and both the page test and a controller test fail if the draft goes
  through `displaySafe` again.
- **The editor's quick-action hint.** `extractQuickActions` matched indented
  slashes (`^\s*/`), so the editor still listed ` /close` as a command after the
  preview had disabled it. GitLab's extractor deletes `\r` and matches `^\/`
  only (`lib/gitlab/quick_actions/extractor.rb`, master, read on 2026-10-22).
  The hint now follows that rule. The existing test that expected an indented
  `/label` to count was changed to match GitLab.

Emulator runs on the project's Android API 36 emulator:

- **Synthetic (`tool/emulator_ai_comment.dart`, gate on, commit `03df08d`).**
  - The preview showed the confidential warning, mentions turned off (1),
    quick actions turned off (1 line), references (1), the source
    `Read issue · #7`, and the text with `` `@synthetic-reviewer` `` and
    ` /close`.
  - "Keep mention notifications" listed `@synthetic-reviewer` and restored the
    text.
  - Confirming opened the ordinary editor after the existing draft. The fixture
    write count stayed 0 until Save, then became 1.
  - The refreshed thread rendered the mention as code and `/close` as text.
- **Real account and provider (gate-on build of `b6e24f3`).**
  - OpenCode Go, Chat Completions, `glm-5.3-flash`; the key went in through
    stdin into the obscured field. The chat was opened on the public MR !98 of
    this project.
  - The first answer, on the build before the line-break fix, showed the bug
    above. The preview of that answer also turned `@username` into code and
    counted `!98` as a reference.
  - After the fix, a multi-paragraph answer with a heading and a list kept its
    lines in the preview and in the editor.
  - The editor was closed without Save; no GitLab write was made with the
    token.
  - The provider was deleted and the account removed afterwards. The emulator's
    original APK was reinstalled and its installed SHA-256 matched the saved
    copy.

**NOT_RUN:**
- a live answer that reads a confidential issue (no private data was used);
- the preview's Arabic and landscape layouts on a device (widget tests only);
- iOS and physical devices.

#### Review round 1 (Codex GPT-6.1-Sol, Opus 5.5; both REQUEST CHANGES)

- **Codex C1, encoded mentions in raw HTML.** `package:markdown` keeps a raw HTML
  block as source text, so `<div>\n&#64;victim\n</div>` reported no mention,
  although GitLab decodes the entity. This round added a small entity table.
  Round 2 replaced it with an HTML parser, see below. A mention that exists
  only after decoding cannot be wrapped, so it is listed and must be
  acknowledged. Covered cases: `&#64;victim`,
  `@&#118;ictim`, `&commat;all`, `&#64;group/subgroup`, and 51 encoded blocks.
  `&#64;` is no longer counted as reference `#64`.
- **Opus C1, the waiting draft changes how the answer parses.** The editor posts
  `existing + "\n\n" + answer`. An unclosed fence or a list in the existing
  draft can move `@Override` or an indented `@Test` out of code.
  - The chat now reads the waiting draft first, through `readCommentDraft`.
    That is the same key the editor uses, read after the account's pending
    draft writes.
  - It analyses the joined text (`analyzeDraftMentions(existing: …)`) and
    wraps only candidates in the answer.
  - It reports only the mentions and references the answer adds.
  - The preview says the answer goes after the unsent draft. If the draft
    cannot be read, nothing is appended and a notice says so.
  - The editor itself, since !98, also refuses to append to a draft it cannot
    read. The plan had said to append without saving; failing closed is kept
    deliberately.
- **Both, a stale target.** The run registry keeps a conversation by origin key,
  so a conversation opened while an issue was confidential kept that value after
  the issue was made public. The origin no longer carries confidentiality. The
  page passes an `AiDraftTarget` with `existingText`, `confidential` and `insert`,
  and `confidential` is read from the page's current data when the answer is
  appended.
- **Opus I1, analysis time.** A 64,000-character answer with 50 candidates took
  about 1.7 s on a Mac. Drafts from 4,000 characters run on another isolate
  (`Isolate.run`). Both results are computed once before the sheet opens, and
  the append button shows a progress indicator meanwhile. The preview shows at
  most the first 6,000 characters and says that the editor shows the rest.
- **Re-checks after the sheet.** Inserting now requires that the chat page is
  still the current route, the conversation is idle, and the answer is still in
  it. Otherwise a notice says nothing was appended. Each condition has its own
  test: a page pushed as the sheet closes, a phase change, and a replaced
  conversation.
- **Opus I4, internal notes.** Tool results now carry `readInternal` when
  `get_issue` or `get_merge_request` returned a non-system note with
  `internal: true` (or the older `confidential: true`). The page's own context
  chip carries `internal` when it included such a note, set in
  `AiChatController._sentChip` from `AiBuiltContext.readInternal`. Either one
  shows a warning whatever the target, because an ordinary comment is visible
  to everyone who can see the item. Neither flag reaches the provider: request
  bytes are compared with each flag off, on, and both on, for all three
  formats. History stores either flag only when true.
- **Runner.** The runner rebuilt each tool result without the display flags, and
  the controller re-attached them by call id. The runner now carries
  `readConfidential` and `readInternal` itself, only for successful reads; the
  controller's workaround is gone.
- **Strings.**
  - "Quick actions" now uses each catalog's existing `quickActionsTitle` term.
  - The notice counts mentions that notify, not users, because `@all` and a
    group reach many people.
  - "Mentions turned off" is limited to this answer.
  - English no longer says "1 lines".
  - New: the internal-note warning, the existing-draft note, the cut preview,
    "conversation changed" and "draft unreadable" notices.
- **Mutations in this round.** Each of these removals turned its test red:
  - not passing the existing draft to the analysis;
  - not asking the target for its confidentiality;
  - dropping the internal warning;
  - dropping the route check;
  - dropping the `contains(item)` check;
  - replacing the page's confidentiality wiring with a constant. A value
    captured when the chat opened was not caught until round 2.
- **Not changed:**
  - `x @. y` becomes ``x `@`. y``, which is cosmetic and safe.
  - A new conversation that keeps the old items on screen also counts their
    confidential reads, which over-warns.

#### Review round 2 (Codex GPT-6.1-Sol, Opus 5.5; both REQUEST CHANGES)

- **Entities, again (both).** The table missed:
  - numeric references without a semicolon, which the HTML5 tokenizer still
    decodes: `&#64victim`, `&#x40victim`, `&#X40victim`;
  - named entities outside the table: `&fjlig;` gives `fj`, `&UnderBar;`
    gives `_`.

  The analysis now uses `package:html`, promoted from a transitive to a direct
  dependency at the locked 0.15.7; the lock changed only in that entry's
  `dependency:` line.
  - Every Markdown text node is parsed as an HTML fragment. Raw HTML blocks are
    included, and Markdown text is already escaped, so this decodes exactly
    once.
  - The final mention count walks the DOM of the whole rendered note, text node
    by text node. It skips `code` and `pre`, and reads text nodes only, never
    attributes. This matches GitLab 18.11 and later; round 3 below adds the
    older parser.
  - `&amp;#64;victim` stays text. `<div title="@alice">` is no longer reported.
  - The tests compare against a render-and-parse check (`markdownToHtml`, then
    `package:html`) that calls nothing in the analyzer. It is not independent:
    it shares the HTML5 parser and the mention pattern. It covers the fixed
    corpus of both reviews and 600 generated answers, each alone and after an
    existing draft.
  - A 3,990-character answer with 50 candidates took about 52 ms in JIT on a
    Mac, but only in a benign layout; see round 3.
- **CR in the waiting draft (Codex).** GitLab deletes every CR of a comment
  before rendering when it processes quick actions. With an existing draft of
  `log\r` + three backticks, the backticks start a fence locally but end up
  mid-line on GitLab. The analysis now applies the same CR handling to the
  existing draft and to the answer.
- **CR before redaction (Opus).** `draftSafe` kept CRs, and they were removed
  only later by `neutralizeForGitLabDraft`. A known secret split by a lone CR
  therefore passed redaction and was then joined back together. `draftSafe`
  now drops CRs first. A controller test covers a split secret.
- **Page-boundary tests (Opus).** Three mutations had survived: an empty
  `readDraftField`, an empty `existingText` on the page, and confidentiality
  captured when the chat opened. A new entry-point test now saves a draft
  under the real key and expects `existingText()` to return it. It also checks
  that the preview shows the existing-draft note, and that a target created
  earlier reports the issue as public after the page reloads. All three
  mutations now turn it red.
- **Smaller fixes.**
  - `readCommentDraft` refuses a draft whose write marker the editor would
    also refuse, so the preview does not open for an append that would not
    happen.
  - A failed analysis says the answer could not be checked; nothing is
    appended.
  - When another page covers the chat, no "conversation changed" notice is
    shown.
  - A 6,001-character answer now gets the "preview cut" note.
  - The existing-draft note no longer points "above". It says mentions and
    references are checked on the joined text and that the user's own draft,
    including its quick actions, is left as it is.
  - The notify count is limited to this answer.
  - Thai uses its existing quick-action term.
- **Residual, documented here.** The check covers the joined text at the
  moment of appending. If the user then edits their own part of the draft in
  the editor, for example by closing a fence they had left open, a mention
  that was inside that code can become live. The editor's Save is not checked
  again.

#### Review round 3 (Codex: APPROVE WITH MINOR FIXES; Opus: REQUEST CHANGES)

- **Two GitLab parsers (Opus I1).** GitLab 18.11 and later parse note HTML with
  HTML5 (Gumbo). Earlier self-managed releases use libxml2's HTML4 parser.
  - Under HTML5 an unclosed raw `<code>` is rebuilt in the next paragraph, so
    the round-2 analyzer treated later mentions as code. libxml2 closes it, and
    the mention is live there. Example: `Wrap the value in a <code>
    element.\n\nThanks @victim`.
  - The analysis now takes the union, per name the larger count, of:
    - the whole-note HTML5 scan;
    - a scan of each Markdown text node as its own fragment, which skips only
      code that Markdown itself produced.
  - The verify-by-reparse step uses the same union.
  - The reviewer's 4,000-document fuzz was compared with Nokogiri's libxml2
    and Gumbo parsers using GitLab's XPath. Documents with a mention the
    analyzer neither wrapped nor listed: 0 under libxml2, 4 under Gumbo. The 4
    are malformed `code`/`textarea` tag combinations.
  - Raw `<code>@x</code>` and `<pre>@x</pre>` are now over-reported, wrapped
    or listed, as before round 2. The tests say which expectations changed.
  - Whether GitLab actually notifies in these cases is still `NOT_VERIFIED`.
    No `POST /markdown` was made, and no instance older than 18.11 was used.
- **Raw anchors (Codex M1).** A raw `<a href=".../-/issues/123">` is counted as
  a reference again, from the rendered DOM. A Markdown link to the same URL
  is not counted twice.
- **Speed (Opus I3).**
  - A short answer can still be slow. `package:markdown`'s GFM autolink scan is
    quadratic on a long unbroken run of letters, and each candidate reparsed
    the whole draft. So 50 mentions before 3,500 `x` took about 15 s.
  - Candidates are now wrapped all at once and verified in one reparse,
    falling back to one by one only if that check fails.
  - Measured in JIT on a Mac: that case 504 ms, 10 mentions before 3,900 `x`
    632 ms, `'x' * 6000 + 'Z'` 756 ms, the benign layout 3 ms.
  - The page now always runs the check on another isolate, whatever the
    length. It gives up after 30 s and then appends nothing ("The answer could
    not be checked"). Round 4 below makes giving up stop the work.
  - `AiChatPage.analyzeDraft` lets tests run the check in place. The entry
    point tests and one page test use the real isolate.
- **Flaky test (Opus I2).** The long-answer test used `'x' * 6000`, the parser's
  slowest input, under a fixed two-second wait, so it failed on a loaded
  machine. It now waits for the preview itself, up to 10 s, and uses `'x ' *
  3000 + 'Z'`.
- **Notices.** The unreadable, check-failed and changed notices all appear only
  while the chat is in front. Tests cover a covered chat (searching offstage
  too) and a failing check.
- **Strings.** Malay uses its existing "quick action" term in the
  existing-draft note.

#### Review round 4 (Opus: APPROVE WITH MINOR FIXES; Codex: REQUEST CHANGES)

- **A timed-out check kept running (Codex Important; Opus N2).**
  `Future.timeout` only stopped the wait. The isolate went on until the
  analysis finished, and a retry started another.
  - The check now runs through `runWithDeadline`. It spawns its own isolate and
    kills it on timeout, on error, or when it is done.
  - Tests:
    - a worker that keeps sending heartbeats stops sending them after the
      deadline;
    - a pathological draft (49 mentions, one candidate already in code, then
      12,000 `x`) gives up at a 300 ms deadline instead of running to the
      end;
    - failures are reported.
  - Removing the kill, the timeout, or the isolate each turns a test red.
  - Leaving the chat does not cancel a check in progress; the 30 s deadline
    still bounds it.
- **References for both parsers (Codex M1; Opus N1).** References now use the
  same two views as mentions: the whole-note HTML5 DOM, and per-text-node
  fragments that skip code and pre inside each fragment.
  - Each view subtracts the existing draft's own references, and the larger
    total is reported.
  - An anchor is counted once in either view.
  - After an unclosed raw `<code>`, `#123` and `!45` count 2 again.
  - On a 3,000-answer natural corpus, the number of answers where libxml2 sees
    a reference that the preview shows as 0 went from 1,364 to 0. Gumbo
    stayed at 0.
  - Malformed HTML still differs in some cases (28 under libxml2, 3 under
    Gumbo, out of 3,000).
- **Tests the reviewers found missing (Opus N3).**
  - `see <textarea> @victim and <div>@raw</div>` must keep `neutralized == 0`
    and the text unchanged. Removing the fallback's "exactly one mention
    fewer" condition now fails it.
  - The timeout and the isolate are covered as above.
- **Limits, stated plainly (Opus N4, N5).**
  - Over-reporting is broader than raw `<code>@x</code>`. Ordinary Markdown
    such as `~~a_@victim~~` is listed. After an unclosed `<code>`, `<pre>` or
    `<textarea>` in the existing draft, mentions that GitLab 18.11+ would not
    notify are still listed for acknowledgement.
  - Under-reporting remains possible only for malformed tag combinations, in
    two ways:
    - the two views cut a name differently (`victim--` against `victim`);
    - a name the existing draft already mentions cancels the answer's
      occurrence.
- **Not done, recorded as follow-ups.**
  - Reading the instance version (`GET /version`) to pick one parser instead
    of the union.
  - Cancelling a running check when the chat closes.

#### Review round 5 (Codex, Opus and cursor-agent: all APPROVE WITH MINOR FIXES)

No Critical or Important findings were left, so the round-5 Minors followed
the review fast path: fixed here, then one reviewer checked the increment.

- **Deadline tests.**
  - The heartbeat test used to assume the worker started within 300 ms and
    stopped within fixed windows. It now only checks that heartbeats stop
    after the deadline. It waits up to 10 s for half a second without one, and
    no longer requires the worker to have started. A killed worker goes quiet.
    One left running keeps sending, so removing the kill still fails the test,
    unless that worker had not even started half a second after the
    deadline.
  - A failing worker's own error now comes back as a `RemoteError` carrying
    its message; before, it was a generic `StateError`. The test checks the
    message.
- **Over-reporting, stated more fully.**
  - The per-fragment reference view adds safe over-reporting: raw `<code>` or
    `<pre>` content that Markdown splits into several text nodes counts in
    later fragments. That was 93 of 3,000 natural answers in Opus's round-5
    corpus.
  - An unclosed `<pre>` in the existing draft over-reports under libxml2 as
    well, not only under HTML5.
- **Left for follow-up**, in
  [work item 10](https://gitlab.com/aa22396584/gitlab-mobile/-/work_items/10):
  - a test for the branch where a Markdown link ends a raw anchor (a mutation
    survives because both views usually agree);
  - choosing one parser from the instance version;
  - cancelling a check when the chat closes.
