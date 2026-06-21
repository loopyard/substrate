# Substrate

> An AI harness where the agent is given a *computer*, not a menu of tools — a
> Turing-complete, sandboxed, live-mutable machine whose I/O is
> capability-secured and whose blast radius is bounded by construction.

*Status: design notes, captured live from conversation. Last updated 2026-06-20.*

---

## The one-sentence thesis

**Safety enables capability.** Almost all agent-safety work *removes* ability —
sandbox the agent so it can do less. Substrate inverts it: make the floor
*unbreakable*, and then you can safely hand the agent *more* — a Turing-complete
language, the right to write and persist arbitrary software, even the power to
extend its own surface. You can only give an agent a loaded language if it
cannot break the floor.

The agent today is timid because we're terrified of it and one mistake is
catastrophic. Substrate makes mistakes *cheap*, so the agent gets to be **bold**.

---

## The stack

```
L3  Harness    — untrusted reasoner; introspects -> writes software -> re-observes
─── membrane   — intent -> disposition; adjudication pipeline; human/agent oversight
L2  Substrate  — Turing-complete sandboxed Lisp; capability-secure;
                 self-describing (code = data = docs); LIVE & mutable surface
L1  Libraries  — native Gmail / GitHub / ... clients (full authority)
L0  Runtime    — Elixir / OTP; tokens, sockets, env, supervision, hot-swap
```

| Layer | Role | Trusted? | Holds |
|---|---|---|---|
| **L3 Harness** | reasons, plans, writes & runs software | **no** | nothing but context |
| **membrane** | adjudicates intent into a disposition | **yes** | queues, rate state, policy |
| **L2 Substrate** | sandbox, capability surface, self-description | **yes** | opaque capability handles |
| **L1 Libraries** | native API clients | yes | real API logic |
| **L0 Runtime** | supervision, authority | yes | tokens, sockets, env |

---

## L0 — Runtime (Elixir / OTP)

The boring, solved, *trusted* base. Holds the genuinely dangerous things: real
OAuth tokens, raw sockets, env vars. Provides supervision, concurrency,
long-lived processes, and — critically — **hot code loading**, which is what
makes the live-mutable surface at L2 cheap instead of exotic.

## L1 — Libraries

Native clients (Gmail, GitHub, …). Full authority, ordinary API code. Well
understood; not where the novelty is.

## L2 — Substrate (the namesake)

A **Turing-complete, sandboxed scripting language** (Lisp / Scheme leaning) that
is the *only* thing L3 ever touches. Properties:

- **Capability-secure, not policy-secure.** The sandbox has *zero ambient
  authority*: no `os.getenv`, no FFI / eval-to-native, no filesystem, no raw
  http. It receives **opaque capability handles**, never credentials. There is
  no expressible operation that *returns* a token — the credential never enters
  the sandbox's value-space at all. Prompt injection degrades from "credential
  theft" to "scoped misuse of an already-granted capability."
- **Self-describing — code = data = docs.** Because it's a Lisp, the capability
  surface, its docstrings, its schemas, its examples, and its native binding are
  *one declaration*. The agent reads its action space in the same form it writes
  actions. No drift between "what the docs say" and "what you can do" — they're
  the same sealed object. Kills hallucinated tool calls by construction.
- **Live & mutable.** The capability surface is *data in a registry*, not
  compiled into the agent. Changing the agent's abilities = an atomic update to
  a lookup table (a GenServer message / ETS write), unrelated to any call stack.
  Lisp redefines symbols live; BEAM hot-swaps modules. The surface can change
  *while the agent runs*.

### Example capability declaration ("one place")

```lisp
(capability gmail/send
  "Send an email as the authenticated user. Returns the sent message id."
  (params (to     string  "recipient address")
          (subject string)
          (body    string  "plain text or markdown"))
  (policy  (rate  "100/day")
           (requires-scope "gmail.send")
           (confirm-if (external-domain? to)))   ; -> enqueue for human approval
  (example (gmail/send :to "a@b.com" :subject "hi" :body "yo"))
  (bind    elixir Substrate.Gmail.send/3))         ; native edge — invisible to agent
```

The agent sees everything above `bind`. It can *never* see or reach
`Substrate.Gmail.send/3`; that symbol resolves only in L0.

## The membrane — intent becomes (or doesn't become) effect

The agent is **credential-blind by design** — it doesn't know auth *exists*, so
it never spends a reasoning token hunting for an API key. It only expresses
**intent**; the membrane is the **reality principle** that decides if/when/how
intent becomes effect.

- **A capability returns a *disposition*, not a value:**
  `:done` (+result) · `:queued` (pending approval, + handle) ·
  `:rate-limited` (+retry-after) · `:denied`.
- **Adjudication is a pluggable, possibly *intelligent* pipeline.** What decides
  the disposition can be a static rule, security software scanning the call,
  *another agent* monitoring, or a human — composed per capability.
- **Proposer / disposer split.** The untrusted L3 actor only *proposes*. The
  trusted intelligence lives *in the membrane* and *disposes*. Two minds on
  opposite sides of the wall: a fast, creative, reckless actor and a slow,
  skeptical adjudicator. The wall is what lets the actor be reckless.
- **Oversight is behavioral, not just per-call.** An adjudicator watches the
  *stream* ("40 borderline emails this hour → clamp"). Fraud detection on the
  agent's own actions.
- **Bounded watchers.** The monitor agent can itself be a substrate harness —
  capability-limited, so the overseer can't be subverted either. The proposer
  can attach a **rationale** to a call so the adjudicator reasons about intent.

## L3 — Harness (untrusted, attached)

The LLM loop. **Attaches** to a live substrate from *outside* the trust
boundary, like a debugger attaching to a process or a REPL to a live image. The
substrate enforces identically no matter what drives it — Opus, an open-weights
model, a swarm, a human. Loop: **attach → introspect the surface as data →
plan → emit substrate code → substrate clamps + executes → observe disposition →
repeat.** Introspection *first*: the agent does science on its own environment,
and the environment is honest because the docs *are* the enforcement.

---

## Two clamps + two contracts

The agent is bounded on **both** ends:

- **Input clamp** (capability wall): can't *reach* authority — no token to steal.
- **Effect clamp** (membrane): can't *unilaterally act* — intent ≠ effect.

"Can't break shit" is three isolations, one per layer:

- **Can't break the host** — capability wall (worst case: scoped misuse).
- **Can't break the world** — membrane (effects queued + rate-clamped).
- **Can't break itself** — OTP supervision (crash → isolate → restart → heal).

### Stability model: a syscall ABI

The capability **namespace is an ABI**; the disposition is **errno**.

- **Frozen interface.** A capability's *name + signature* is a stable contract,
  like a syscall number. Software the agent builds on it keeps its shape.
- **Dynamic behavior.** *Whether a call succeeds* — permission, rate, approval —
  is decided fresh at call time by the adjudication pipeline. Same call,
  different errno in different moments/contexts.
- This *revised* an earlier idea ("denial-by-absence"): don't make a revoked
  capability *vanish* (that shatters the agent's software with "undefined
  function"). Keep the signature; return `:denied`. The agent already knows how
  to handle a disposition.
- Split the surface: a **frozen standard library** (build towers on it) vs
  **discoverable/volatile capabilities** (treat as weather).

### Substrate promises *safety*, not *stability*

A normal platform promises "your code keeps working" (backwards-compat).
Substrate promises "when your code breaks, *nothing catches fire*." Software
built on a vanished/changed capability just fails when called, gets supervised,
and the agent re-observes and rebuilds. The property is **antifragility**, not
stability — the agent can always rebuild without burning the house down.

---

## Open forks (undecided)

1. **Language: Lisp vs Lua/Luau.** Lisp → homoiconicity (code=data=docs, static
   inspection, clean capability injection) but LLMs write less of it. Luau →
   proven embeddable sandbox, model-fluent, but stock Lua leaks (`io`/`os`/
   `package`) and you lose homoiconicity. Tension: *safest to sandbox* ≠ *most
   fluent for the model*.
2. **Disposition delivery: handle vs event.** Does the agent get an awaitable
   handle to a pending effect (`(await h)` suspends), or is it fully
   event-driven (the result reappears later as a new observation)? Determines
   whether the harness loop is synchronous-with-suspension or event-driven.
3. **How honest is the membrane?** Leaning **honest-but-abstract**: the agent
   sees `:queued` / `:rate-limited` so it can back off, but never learns the
   *mechanism* (never learns auth exists). Fully-naive risks thrash (re-send 100×
   thinking it failed); fully-transparent leaks the model of the wall.
4. **Surface disclosure.** Whole-surface-up-front vs lazy `(describe …)` vs
   namespaced/progressive — and now *dynamic*, since the surface mutates live.
5. **Can the agent grow the substrate?** Compose capabilities into a named,
   persisted substrate function (same enforcement)? Growth = just another writer
   to the registry. Leaning **yes** — that's the version that's actually new.
6. **One harness or many?** "Substrate" hints at a shared medium — N agents
   attached to one living substrate, coordinating through it. 1:1 or N:1?
7. **Consistency unit under mutation.** Proposed: **snapshot-per-emission** (one
   script runs against a frozen surface; between emissions it's free to change).
   Real subtlety = **queued effects**: capability revoked after enqueue but
   before approval — **pin** version at enqueue, or **re-validate** at approval?
   (Governance probably wants re-validate; make it per-capability.)
8. **Adjudication latency.** Can't run an LLM monitor on every call. Needs
   **tiered adjudication**: cheap static rules fast-path ~99%, escalate to
   agent/human only on flagged calls.

---

## Why this is new (positioning)

- **vs MCP / tool-calling:** there the tool process holds `GITHUB_TOKEN` in its
  env — one confused-deputy bug exfiltrates. Substrate's reasoner has no token
  to steal, and emits *programs* (loops, conditionals) not one JSON call/turn.
- **vs CodeAct / code-as-action:** points the same direction (model emits code),
  but substrate adds the capability wall, the live self-describing surface, the
  disposition membrane, and OTP supervision — the secure, live, self-extending
  version.
- **vs LangGraph / raw API loops:** those *fuse* reasoner + tools into one
  trusted process; the model's judgment *is* the security boundary. Substrate
  *splits* them at the membrane and demotes the reasoner to an untrusted client.

---

## Likely first proof-of-concept

Smallest kernel that makes the central claims real instead of slideware:

- Elixir + a tiny sandboxed Lisp evaluator with **zero ambient authority**.
- One capability — `gmail/send` → just logs — declared "in one place."
- The **disposition** return type (`:done` / `:queued` / `:rate-limited` / `:denied`).
- A live registry you can mutate at runtime to demonstrate **denial-by-`:denied`**
  on a *frozen* signature (the ABI/errno model).
- A REPL an agent can **attach** to and `(describe …)` the surface.

Goal: demonstrate the **credential wall** and **static-surface / dynamic-disposition**
are structural, not vibes.
