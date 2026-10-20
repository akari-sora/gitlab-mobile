# v0.6 AI verification ledger

MR1 implements the plain-Dart security core only. `MERGELINE_AI_ASSISTANT`
defaults to false. No AI controllers, settings, entry points, or provider calls
are wired into the application by this slice (plan §9.1–§9.2).

## Evidence boundaries

| Lane | MR1 scope / status |
| --- | --- |
| Endpoint policy, SSE, failures, redaction, transcript and provider contracts | FIX1 source is commit `1abb72960ff544c803db75ce88302ac88380701d`; FIX2 source is commit `a1ba0432ef86440222f058bb74b07ca62b05a193`. Pipelines pending. FIX3 source is commit `8bf0bd6b43887d9b9df1a2e130d51c55b1e5f3b3`. FIX4 source is commit `bdefd6c431ad93ce0a9ef72fd4f139b69a2dec4c`. FIX5 source is commit `5da74eab3cb02fc6d327ce934b2d591fe8d8f541`. FIX6 source is commit `7b83c9205d4b2cf2fd2b62604742197b14cf18b4`. FIX7 is the commit that adds this sentence. Local synthetic checks do not establish CI acceptance. |
| Existing Flutter behavior | Original author reported a full-suite pass; no retained receipt or job URL is available here. FIX1 does not rerun the full Flutter suite. |
| Localization | All 24 catalogs contain AI translations at `bafe8ad`; FIX1 adds no messages. Catalog generation and translation guards are checked locally. |
| GitLab/private-resource integration | NOT_RUN; MR1 does not use the GitLab API |
| Native provider conformance / P0 | NOT_RUN; plan §9.4, before MR2 |
| Android/iOS, accessibility and AOT performance | NOT_RUN; subsequent device/release lanes |
| Pipeline / job URLs | FIX1 `1abb72960ff544c803db75ce88302ac88380701d` and FIX2 `a1ba0432ef86440222f058bb74b07ca62b05a193`: pipelines pending; no verified job URL retained here. FIX3 `8bf0bd6b43887d9b9df1a2e130d51c55b1e5f3b3`: pipeline pending. FIX4 `bdefd6c431ad93ce0a9ef72fd4f139b69a2dec4c`, FIX5 `5da74eab3cb02fc6d327ce934b2d591fe8d8f541`, FIX6 `7b83c9205d4b2cf2fd2b62604742197b14cf18b4` and FIX7: pipelines pending. |

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

`Redactor.redact(input, fragment: true)` is the executable contract for the
rest: when the caller passes text cut from a larger source, any private-key
marker withholds the whole fragment as `[REDACTED:private_key_fragment]` (and
sets `withheldPrivateKeyContext`); fragments without a private-key marker use
the ordinary rules. Regressions cover the round-7 shape, single BEGIN/END
markers in a fragment, a marker-free fragment and the placeholder collision
check; the same text as a complete source keeps its context.

Invariants for the context builders and tools (MR4), in addition to those
above: redact a complete source (a whole file, a finished job's whole trace)
before cutting excerpts from it; pass `fragment: true` for every input that is
cut from a larger source and not redacted whole first (a trace read from a
non-zero offset of a running job, a diff hunk, a line range); keep the
sensitive-path filter for diffs. A key cut at both ends with no marker inside
the text at all cannot be recognised by markers in any mode; that residual
stays documented here.

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
