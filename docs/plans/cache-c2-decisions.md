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
