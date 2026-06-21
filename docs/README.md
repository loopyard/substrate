# Substrate docs

How Substrate works, written to be read top to bottom. If the whole thing feels
weird, start with **overview** — its entire job is to make the weirdness
ordinary.

One mental model carries the whole system:

> **Substrate is an operating system; the agent is a userland process.**
> Capabilities are syscalls. Dispositions are `errno`. The membrane is the
> kernel's permission check. Humans sit inside the kernel.

## Reading order

| # | Doc | What it covers | Status |
|---|-----|----------------|--------|
| 1 | [overview.md](overview.md) | The mental model; the five inversions and why each is ordinary | ✅ |
| 2 | [architecture.md](architecture.md) | The five layers end to end; trust boundaries | ✅ |
| 3 | [capabilities.md](capabilities.md) | The capability declaration; opaque handles; the self-describing surface | ✅ |
| 4 | [membrane.md](membrane.md) | Dispositions; the adjudication pipeline; the approval queue; proposer/disposer | ✅ |
| 5 | [harness.md](harness.md) | Attach; the loop; the wire protocol; code-as-action | ✅ |
| 6 | [language.md](language.md) | The substrate Lisp: what's in, what's out, ephemeral vs persisted definitions | ✅ |
| 7 | [lifecycle.md](lifecycle.md) | The live surface; ABI/errno stability; snapshot-per-emission; revocation & queued effects | ✅ |
| — | [gmail.md](gmail.md) | Worked example: author a Gmail substrate, then call it | ✅ |

For the *open* questions and design decisions still in flux, see
[../DESIGN.md](../DESIGN.md) — that's the decision log; these docs are the "how
it works."
