# Recorded wire fixtures

RECORDED on 2026-10-20 from the P0a packet. `index.json` lists the
path, model, direct/proxy/local route, status and scenario for each recording.
Each SSE/JSONC file also retains its original provenance header.
`responseBytes` is the current fixture file size including comments;
`sourceResponseBytes` is the original capture's body size from the packet.

All opaque provider values are **synthetic**: thinking signatures, encrypted
reasoning, message/response/item/tool/request IDs, obfuscation, fingerprints,
and any non-null account identifiers. Replacements are deterministic across
all requests and responses, preserve character classes, lengths and ID
prefixes, and are deliberately invalid for provider authentication/replay.
Values are generated from one-way digests, not a reversible character cipher.
Signature chunk replacements are slices of the synthetic complete signature,
so reconstruction agrees with subsequent request fixtures. Replacement is
scoped to JSON values; ordinary text and provenance are never globally changed.
They prevent opaque account-bound material from entering a public repository.
SSE event order, JSON field order and whitespace are retained except the
provenance comment and same-shape opaque replacements. These files are decoder
fixtures, not credentials and not evidence that synthetic ciphertext works
against a provider. Source and output were scanned for both forbidden key
prefixes before writing. No keys were read.
