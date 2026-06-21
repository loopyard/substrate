# Architecture — the five layers, end to end

[overview.md](overview.md) gives you the model (Substrate is an OS; the agent is
a userland process). This doc makes it concrete: the five layers, what each one
holds, where the trust boundaries actually fall, and what happens to a single
call as it travels down the stack and back.

```
L3  Harness    — untrusted reasoner; introspects -> writes software -> re-observes
─── membrane   — intent -> disposition; adjudication pipeline; human/agent oversight
L2  Substrate  — Turing-complete sandboxed Lisp; capability-secure;
                 self-describing (code = data = docs); LIVE & mutable surface
L1  Libraries  — native Gmail / GitHub / ... clients (full authority)
L0  Runtime    — Elixir / OTP; tokens, sockets, env, supervision, hot-swap
```

The single most important thing to read off this picture: **trust increases as
you go down.** The only untrusted layer is the one with the LLM in it. Every
layer below the membrane is ordinary, trusted, well-understood software. The
novelty is not in any one layer — it's in *where the wall is drawn* and *what
crosses it*.

| Layer | Role | Trusted? | Holds |
|---|---|---|---|
| **L3 Harness** | reasons, plans, writes & runs software | **no** | nothing but context |
| **membrane** | adjudicates intent into a disposition | **yes** | queues, rate state, policy |
| **L2 Substrate** | sandbox, capability surface, self-description | **yes** | opaque capability handles |
| **L1 Libraries** | native API clients | yes | real API logic |
| **L0 Runtime** | supervision, authority | yes | tokens, sockets, env |

---

## L0 — Runtime (Elixir / OTP)

The boring, solved, *trusted* base — and the only place the genuinely dangerous
things live: real OAuth tokens, raw sockets, environment variables. Nothing
above L0 can name them.

L0 is Elixir on the BEAM, and it is chosen for three properties that the upper
layers depend on:

- **Supervision.** Every emission runs as a supervised process. A bad program
  crashes *its own process* and is isolated, restarted, or dropped — it cannot
  take down the substrate. This is the "can't break itself" isolation, and it's
  why the agent is allowed to write reckless code (see [harness.md](harness.md)).
- **Concurrency & long life.** A substrate is a long-lived stateful process an
  agent attaches to, not a request/response endpoint (see
  [lifecycle.md](lifecycle.md)). The BEAM is built for exactly this.
- **Hot code loading.** The live-mutable surface at L2 is *cheap* precisely
  because the BEAM already hot-swaps modules at runtime. What would be exotic
  elsewhere is a solved primitive here.

L0 is the kernel's privileged core. Think of it as ring 0 holding the page
tables and the device drivers.

## L1 — Libraries

Native API clients — Gmail, GitHub, and so on. Full authority, ordinary code,
nothing novel. An L1 module receives a credential *handle* (`ctx`), fetches the
real token from the L0 vault, and makes the actual API call. It runs entirely
inside the trust boundary.

The agent can never name, call, or see an L1 module. In the Gmail example
([gmail.md](gmail.md)) the entire `Substrate.Gmail` module is L1: it touches the
token; it is invisible to the harness. L1 is where the rubber meets the external
world — device drivers, in the OS analogy.

## L2 — Substrate (the namesake)

A **Turing-complete, sandboxed scripting language** (Lisp-leaning; see
[language.md](language.md)) that is the *only* thing L3 ever touches. Three
properties define it, each covered in depth elsewhere:

- **Capability-secure, not policy-secure** — zero ambient authority. No
  `os.getenv`, no FFI, no filesystem, no raw HTTP. It receives **opaque
  capability handles**, never credentials. There is no expressible operation
  that *returns* a token. See [capabilities.md](capabilities.md).
- **Self-describing — code = data = docs.** A capability's purpose, schema,
  example, and native binding are one declaration. The agent reads its action
  space in the same form it writes actions. See
  [capabilities.md](capabilities.md).
- **Live & mutable.** The surface is *data in a registry*, not compiled into the
  agent. Changing abilities is an atomic registry write, while the agent runs.
  See [lifecycle.md](lifecycle.md).

L2 is the system-call interface and the sandbox the userland process lives in.
It is trusted code — but it is the *last* trusted code, sitting right against the
wall.

## L3 — Harness (untrusted, attached)

The LLM loop. It **attaches** to a live substrate from *outside* the trust
boundary — like a debugger attaching to a running process, or a REPL to a live
image. It introspects the surface as data, plans, emits substrate code, and
observes dispositions. The substrate enforces identically regardless of what
drives L3: a frontier model, an open-weights model, a swarm, or a human at a
REPL. See [harness.md](harness.md).

L3 holds **nothing but context**. It is the one component the system does not
trust, and the whole architecture is arranged so that not trusting it costs
nothing.

---

## The two trust boundaries

There are exactly two boundaries that matter, and they clamp the agent on
opposite ends.

### 1. The capability wall (between L3 and L2)

This is an **input clamp**: it governs what authority can ever *reach* the agent.
The answer is none. The agent holds opaque handles — names it can pass to
capabilities — but never a credential, never a native reference, never a file
descriptor to the host. There is no value in the agent's world that *is* a
secret, so there is nothing for prompt injection to steal. The worst a fully
jailbroken script can do is *misuse a capability it was already granted* — and
that misuse runs straight into the second boundary.

### 2. The membrane (between intent and effect)

This is an **effect clamp**: it governs whether intent ever *becomes* a
real-world effect. Every capability call passes through the membrane, which
returns a **disposition** (`:done` / `:queued` / `:rate-limited` / `:denied`)
rather than a raw value. A human or a monitoring agent can sit directly in this
path. The agent proposes; the membrane disposes. See [membrane.md](membrane.md).

> Input clamp: **can't reach authority.** Effect clamp: **can't unilaterally
> act.** Neither relies on the reasoner behaving — both are structural.

---

## Following one call down the stack

Trace `(gmail/send :to "stranger@example.com" ...)` from emission to outcome:

```
L3  Harness     emits the s-expression. Holds no token; only names a capability.
        │  (crosses the capability wall — only the name + args cross, nothing comes back but a disposition)
        ▼
L2  Substrate   resolves gmail/send in the live registry against a frozen
        │       snapshot of the surface; validates args against the declared
        │       schema; looks up the (bind ...) target — invisible to L3.
        ▼
─── membrane    runs the adjudication pipeline for this capability:
        │         RateLimit (static, ~free) -> under budget, pass
        │         ApprovalQueue -> confirm-if external-domain? fires -> ENQUEUE
        │       returns (:queued {:handle eff_42}) back up to L3. No effect yet.
        │       Later: brad approves in the queue. NOW the call proceeds:
        ▼
L1  Library     Substrate.Gmail.send(ctx, %{...}) runs with full authority.
        │       Fetches the real token from L0; calls the Gmail API.
        ▼
L0  Runtime     vault yields the token; socket sends the request; supervisor
                watches the process. Result flows back up as (:done {:id ...}).
```

Two things to notice. First, **the token only ever exists at L0/L1** — it is
fetched on the far side of the membrane and never travels back up. Second, the
agent's program at L3 only ever sees the *disposition* (`:queued`, then later
`:done`), never the mechanism that produced it — honest about the outcome,
abstract about the cause.

---

## The three isolations

"Can't break shit" decomposes into one guarantee per boundary:

- **Can't break the host** — the capability wall (L3↔L2). Worst case is scoped
  misuse of a granted capability; there is no token to exfiltrate.
- **Can't break the world** — the membrane. Effects are queued, rate-clamped, or
  denied before they touch reality; a human can sit in the path.
- **Can't break itself** — OTP supervision (L0). A crashing emission is
  isolated, restarted, and healed; the substrate and session survive.

Each isolation lives in a different layer, and each is ordinary engineering in
that layer. Stacked, they are what let the agent be *bold*: mistakes are cheap
because all three floors hold.

---

Next: [capabilities.md](capabilities.md) for what a capability actually *is*, or
[membrane.md](membrane.md) for how a call becomes a disposition.
