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
them, so 4N stays near 2 MiB; median of three samples after warm-up)
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
and quadratic-mutation logs are retained in the external `RESULT-fix4.md`
receipt. Full-suite, CI, live-provider and device gates remain separate.

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

Review-round acceptance output was kept in the local fix-packet handoffs, not
in the repository; there is no committed root `RESULT.md`. The submitted source is tested directly with pinned Flutter
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

Every command below ran synchronously in a foreground `subprocess.run`; the tool session was awaited to completion. Flutter source and tests remained unchanged during this final sequence. Only this receipt and the inline ledger were finalized afterward.

| Command | Exit | Result |
| --- | --- | --- |
| `/Users/iml1s/fvm/versions/3.47.2/bin/flutter analyze --no-pub` | 0 | strict analysis clean |
| `python3 tool/l10n.py --check` | 0 | 2,078 messages / 24 languages current |
| `python3 -m unittest discover -s tool/tests -p 'test_*.py'` | 0 | 68 tests passed |
| `git diff --check` | 0 | no whitespace errors |
| `/Users/iml1s/fvm/versions/3.47.2/bin/flutter test --no-pub` | 0 | 3,584 tests passed; full suite last |

Exact output tails:

`/Users/iml1s/fvm/versions/3.47.2/bin/flutter analyze --no-pub` — exit 0, 6.635 seconds

```text
Analyzing gitlab-mobile-wt-ai-mr3...
No issues found! (ran in 4.8s)
```

`python3 tool/l10n.py --check` — exit 0, 0.148 seconds

```text
2078 messages in 24 languages; generated files current.
```

`python3 -m unittest discover -s tool/tests -p 'test_*.py'` — exit 0, 0.863 seconds

```text
...Could not start 1Password CLI.
.Pinned Dart executable not found: /var/folders/9w/6m1x9qr10zv2p2sztxyyxyq00000gn/T/tmpe4bummkb/missing-dart
.Credential lookup failed for anthropic-direct.
...............................................................
----------------------------------------------------------------------
Ran 68 tests in 0.746s

OK
2078 messages in 24 languages; generated files current.
```

`git diff --check` — exit 0, 0.144 seconds

```text
(no output)
```

`/Users/iml1s/fvm/versions/3.47.2/bin/flutter test --no-pub` — exit 0, 252.499 seconds

```text
03:47 +3577: /Users/iml1s/Documents/mine/apps/tools/gitlab-mobile-wt-ai-mr3/test/emulator_ui_harness_test.dart: 320dp scaled 2.0x reaches all Health, Display and Project controls (project) without overflow
03:47 +3577: /Users/iml1s/Documents/mine/apps/tools/gitlab-mobile-wt-ai-mr3/test/wide_back_navigation_test.dart: P2-BACK: Wide Two-Pane System Back Navigation Suite Account switch cleanup in wide mode clears active selection and resets navigation hierarchy
dynamic_color: Dynamic color not detected on this device.
03:47 +3578: /Users/iml1s/Documents/mine/apps/tools/gitlab-mobile-wt-ai-mr3/test/emulator_ui_harness_test.dart: 320dp scaled 2.0x reaches all Health, Display and Project controls (project) without overflow
03:47 +3579: /Users/iml1s/Documents/mine/apps/tools/gitlab-mobile-wt-ai-mr3/test/emulator_ui_harness_test.dart: 320dp scaled 2.0x reaches all Health, Display and Project controls (project) without overflow
03:48 +3580: /Users/iml1s/Documents/mine/apps/tools/gitlab-mobile-wt-ai-mr3/test/emulator_ui_harness_test.dart: 320dp scaled 2.0x reaches all Health, Display and Project controls (project) without overflow
03:48 +3581: /Users/iml1s/Documents/mine/apps/tools/gitlab-mobile-wt-ai-mr3/test/emulator_ui_harness_test.dart: 320dp scaled 2.0x reaches all Health, Display and Project controls (project) without overflow
03:48 +3581: /Users/iml1s/Documents/mine/apps/tools/gitlab-mobile-wt-ai-mr3/test/wide_back_navigation_test.dart: P2-BACK: Wide Two-Pane System Back Navigation Suite Account switch cleanup in wide mode clears active selection and resets navigation hierarchy
dynamic_color: Dynamic color not detected on this device.
03:49 +3582: /Users/iml1s/Documents/mine/apps/tools/gitlab-mobile-wt-ai-mr3/test/emulator_ui_harness_test.dart: 320dp scaled 2.0x reaches all Health, Display and Project controls (project) without overflow
03:55 +3583: /Users/iml1s/Documents/mine/apps/tools/gitlab-mobile-wt-ai-mr3/test/emulator_ui_harness_test.dart: 320dp scaled 2.0x reaches all Health, Display and Project controls (group) without overflow
04:09 +3584: All tests passed!
```

Python error strings above are deliberate mocked failure fixtures; they do not indicate real 1Password access or provider requests.

Final full-suite incremental-save measurement: `reads=1 one=0:00:00.002838 conversations26=0:00:00.005589`. Both sizes decrypt only the index during an unchanged small save.

The final full run passes the unchanged decoder performance assertion and protected account-removal tests. The first failure is retained as evidence, not silently discarded; the benchmark was not modified and its host-load sensitivity remains visible in the earlier run.

## MR4 — read-only tools and bounded runner

This working-tree change adds the project-bound read port, ten-tool catalogue,
shared sensitive-path policy, SHA-pinned context builders, untrusted-data prompt
labels, live secrets, interface checks and the bounded conversation runner.
`AiRunnerBinding` observes the existing settings/session owners. The gate is
still false and this slice adds no UI, account write path or dependency.

Evidence vocabulary: the new tests are **synthetic**, using in-memory settings,
`FakeAdapter` / `WorkspaceFixture`, synthetic OAuth rotation and recorded SSE
fixtures. **RECORDED** means decoding the retained P0a fixture and replaying its
provider object through the real encoder; it is not a fresh provider call.
The submitted MR4 base is commit `77f2be5`. Repeatable reversible mutation
scripts are retained outside the repository in the review workspace under
`mutation-scripts/`; their FIX1 rerun evidence and acceptance-command tails are
pending the root agent's external `RESULT-fix1.md`. No pipeline was created by
this local FIX1 pass.

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
