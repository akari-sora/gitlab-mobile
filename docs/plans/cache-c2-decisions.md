# Cache C2 lead decisions (2026-10-23, after plan review round 3)

The C2 breakdown (`c2-breakdown-v3.md`) passed three review rounds (Codex, Opus, GLM; Opus round 3 found two last Importants). The plan area produced new Importants three times, so these decisions adopt the reviewer's recommended fixes literally and amend v3 without another plan round. They override v3 where they differ.

## C2-D1. Barrier failures before a send are certain, not uncertain (Opus r3 N3-1, option (a))
- The `_settle` classification section of `lib/core/ai/tools/gitlab_write_port.dart` (about :791–812) joins **P-C2d1**'s manifest (existing-file cap +1).
- `ApiFailure.readCacheCleanup` with `cleanup.disposition == requestBlockedBeforeSend` settles as `failedCertain` with reason code `readCacheCleanup`; no request was sent, so it is never `writeUncertain`.
- P-C2d1's acceptance adds a journal-state test: a barrier failure or timeout before the send leaves the AI write `failedCertain`, retryable, with zero HTTP.

## C2-D2. Label colours follow GitLab's own format (Opus r3 N3-2)
- `LabelDetail` colour fields accept `^#(?:[0-9A-Fa-f]{3}){1,2}$` and are stored as returned.
- A colour string that does not match is **omitted from that label only**; the rest of the page is still stored (as for unsafe URLs). A wrong type (not a string) still makes the projection null.
- P-C2a and P-C2d1 real-shape fixtures each include a `#f00` label.

## C2-D3. Minors
Fix Opus r3 m3-1 (the contradictory sentence and threshold) in the packet that owns it; m3-2 to m3-4 are one-line notes for their packets. Everything else from round 3 is a follow-up.

# Addenda after P-C2a round 1 (2026-10-24, lead)

These decide the two items round 1 left open (claude2 I-2, I-3) in C2-D2's
style: nullable display fields decided against real shapes, and one plan line
read against its own preamble. They amend §3.2/§3.3 for P-C2a only; later
packets inherit them.

## C2-D4. Pure display fields may be null against real shapes (claude2 r1 I-3)
- These join §3.2's legal-null supplement table: Position/LinePosition
  `old_line` and `new_line` (one side is null on every added or removed
  line), `type`, and `line_range` including its start/end line numbers; and
  Pipeline `name` (null when the project sets no `workflow:name`).
- Everything else keeps the breakdown's non-null rules; a wrong type still
  nulls the whole projection.
- Real-shape fixtures must include a DiffNote on an added line
  (`old_line: null`) and a pipeline with `name: null`.

## C2-D5. E17 text admission follows the app's actual key (claude2 r1 I-2)
- §3.3's E17 row ("同路徑 /raw → text") is read against the same section's
  preamble and §1: raw and text are keyed by `Accept`, not by an extra path
  segment. E17 therefore admits exactly the request `GitLabApi.textFile`
  builds: `projects/:p/repository/files/:file?ref=<sha>` with
  `accept: 'text/plain'` (5 path segments, bodyKind text). The same path
  under a JSON Accept stays FileMetadata (E14), per the Accept-keyed design.
- Fixtures use the URI the app really produces. The transport's `/raw`
  variant carries `lfs=false`, which is not a semantic key, so `_validRequest`
  keeps rejecting it; d1 may revisit that only through a new decision.

## C2-D6. Entry and index writes commit on the caller's isolate (P-C2c blocked, 2026-10-27)
P-C2c stopped because `writeEntry`/`writeIndex` ran the whole transaction, rename included, in a background isolate: the commit lease there is an isolate copy, so a revocation on the main isolate could not stop a late rename, which §4.1, §4.2 and §5.1 forbid ("已撤銷不得rename"). A probe paused the worker before rename, revoked the lease and released it; both writes still committed.
- Writes are two-phase. **Stage** runs in the background isolate: encode, encrypt, capacity check, exclusive temporary file, write, flush. Nothing is visible to readers. The caller's gate is checked before dispatch and when staging returns; a closed gate deletes the temporary.
- **Commit** runs synchronously on the caller's isolate with no await inside: re-check the trusted directory chain, the temporary and destination types and (for the index) the referenced entry files, call the gate, then `renameSync`. Revocation runs on the same isolate, so it cannot fall between the check and the rename.
- A staged handle commits at most once and is not sendable to another isolate; discarding it deletes the temporary. The convenience writers are stage plus commit with an always-true gate, so no path bypasses the gate.
- Staging may create the account directory chain and cannot be aborted once dispatched (`Isolate.run`); the returned future is the quiescence acknowledgement, so the coordinator awaits it before clearing.
- This amends C2b's own files (`lib/core/read_cache_files.dart` and its test) under lead authority, before P-C2c starts.
- Main-isolate cost: an entry commit is the directory-chain check (three lstat calls), the temporary and destination checks and one rename. An index commit adds one non-following type check and one length check per referenced entry, up to 2048: about 9 ms on an M4 Max in a synthetic run (33 ms before the chain check was hoisted), more on mid-range Android (not measured). C2c keeps index commits to the §5.1 cadence (every 2 seconds or 32 entries) and may re-check only the references changed since the last commit if that proves too slow.
