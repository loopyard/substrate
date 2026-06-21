# Lifecycle — the live surface, stability, and what happens when things change

A substrate is not a request/response endpoint. It is a **long-lived, stateful
process** an agent attaches to, whose capability surface can change *while the
agent runs*. This doc covers the live surface, the stability contract that makes
mutation survivable, the unit of consistency, and the genuinely tricky case: an
effect that's queued when the capability behind it is revoked.

---

## The substrate is alive

A substrate starts, holds state, and runs for a long time — like a live image or
a running kernel, not a function you call:

```elixir
{:ok, sub} = Substrate.start_link(name: "brad-inbox-agent")
Substrate.mount(sub, Substrate.Gmail.Manifest, credentials: %{...}, adjudicators: [...])
```

Two kinds of state live in it across an agent's session ([harness.md](harness.md)):

- **The surface** — the capabilities currently mounted, as data in a registry.
- **Session state** — variables and definitions the agent created, which persist
  across emissions within the session (its working memory, partly *in* the
  substrate rather than only in context).

Because the substrate is alive, things can happen to it between the agent's
turns. That is a feature, and the rest of this doc is about making it safe.

---

## The live surface — a registry you can mutate at runtime

The capability surface is **data in a registry**, not code compiled into the
agent. So changing what the agent can do is an atomic registry write — a
GenServer message, an ETS write — unrelated to any call stack:

- **Mount** a manifest → new capabilities appear.
- **Revoke** a capability → it starts returning `:denied`.
- **Re-policy** a capability → same signature, different adjudication.

Lisp redefines symbols live; the BEAM hot-swaps modules (see
[architecture.md](architecture.md), L0). What would be exotic elsewhere is a
solved primitive here. The surface can change *while the agent runs*, and the
agent copes because its loop re-reads the surface each turn (`describe`) rather
than holding a static model. A changed surface is not an error condition — it's
the next observation.

---

## The stability contract: a syscall ABI

Mutation would be chaos without a contract bounding what *kind* of change the
agent can see. The contract is the **syscall ABI / errno** split:

- **Frozen interface.** A capability's *name + signature* is a stable contract,
  like a syscall number. Software the agent builds on it keeps its shape.
- **Dynamic behavior.** *Whether a call succeeds* — permission, rate, approval —
  is decided fresh at call time by the membrane. Same call, different errno in
  different moments (see [membrane.md](membrane.md)).

### Denial-by-`:denied`, not denial-by-absence

An earlier design idea was to make a revoked capability *vanish*. That was
**revised**, and the revision matters: a vanished capability shatters the agent's
software with "undefined function." Instead, keep the signature and return
`:denied`. The agent already knows how to handle a disposition — `:denied` is
just this moment's errno on a still-existing call.

```lisp
;; brad revokes Gmail at 2am. The agent's triage program keeps running:
(gmail/send :to "teammate@acme.com" ...)
=> (:denied {:reason "capability suspended"})   ; signature still exists; agent adapts
```

### Frozen standard library vs volatile capabilities

The surface splits to make this contract usable
([capabilities.md](capabilities.md), [language.md](language.md)):

- **A frozen standard library** — build durable towers on it; it won't move.
- **Discoverable / volatile capabilities** — treat as weather; expect different
  errno, re-check each loop.

Durable software goes on the frozen part; adaptive software goes against the
volatile part.

---

## Safety, not stability

This is the contract that has no exact OS analogue, and it's the thesis in one
line. A normal platform promises **backwards-compat**: "your code keeps working."
Substrate promises something stranger and stronger:

> **"When your code breaks, nothing catches fire."**

Software built on a vanished or changed capability just fails when called, gets
supervised (crash → isolate → restart, the OTP way), and the agent re-observes
and rebuilds. The property is **antifragility, not stability** — the agent can
always rebuild without burning the house down. This inverted promise is what lets
the surface be mutable in the first place: you can afford to change the floor
under a running agent precisely because a broken agent is cheap, not
catastrophic.

---

## The unit of consistency: snapshot-per-emission

If the surface can change at any moment, what stops it from changing *mid-program*
and leaving an emission half-run against two different worlds? The answer is
**snapshot-per-emission**:

- One emission runs against a **frozen snapshot** of the surface. A capability
  cannot appear or vanish *during* a single program.
- **Between** emissions, the surface is free to change.

So within an emission the agent has a coherent world; across emissions it
re-observes. This is why the harness loop is "observe → plan → emit → observe'"
(see [harness.md](harness.md)) — the re-observe step exists precisely because the
snapshot is per-emission, not per-session.

```
emission N    ──runs against snapshot Sₙ──▶  disposition
   (surface may change here)
emission N+1  ──runs against snapshot Sₙ₊₁──▶ disposition
```

---

## The hard case: queued effects under revocation

Here is the real subtlety (DESIGN.md fork 7). An effect is enqueued for approval
under `confirm-if`; it returns `:queued {:handle eff_42}`; it sits in the queue.
*Then* the capability is revoked — after enqueue, but before a human approves.
When approval finally comes, which surface governs the effect?

Two answers, and the choice is per-capability:

- **Pin at enqueue.** Freeze the capability's version at the moment the effect
  was queued; approve and run it against *that* version. Honors the agent's
  original intent under the rules that were live when it acted.
- **Re-validate at approval.** Re-check the effect against the *current* surface
  when the human approves; if the capability was revoked in the meantime, the
  effect resolves `:denied`. Honors the *latest* governance decision.

Governance probably wants **re-validate** — a 2am revocation should mean "and
also cancel the pending sends," not "the pending sends still go." But some
effects (an idempotent confirmation the user is owed) may want **pin**. So the
choice is made **per capability**, in its policy, rather than globally.

```lisp
(gmail/send :to "stranger@example.com" ...)
=> (:queued {:handle eff_42})
;; ... gmail/send revoked while eff_42 waits ...
(await eff_42)
=> (:denied {:reason "capability suspended before approval"})   ; re-validate policy
;; or, under pin policy:
=> (:done {:id "msg_0190..."})                                  ; ran under the pinned version
```

Either way the agent only learns the disposition, never the mechanism — it sees
`:done` or `:denied`, not the revocation race behind it.

---

## Lifecycle, end to end

```
start  ─▶  mount manifests, wire adjudicators, bind credentials at L0
  │
  ├─▶  agent attaches a session
  │
  ├─▶  loop:  observe surface (live) ─▶ emit (snapshot) ─▶ disposition ─▶ observe'
  │            ▲                                                          │
  │            └──────────────── surface may have changed ───────────────┘
  │
  ├─▶  mutations (any time, between emissions):  mount / revoke / re-policy
  │       └─ revoked capability returns :denied (signature stays)
  │       └─ queued effects resolve by pin-or-re-validate policy
  │
  └─▶  crashes are supervised: isolate ─▶ restart ─▶ heal; session survives
```

The substrate lives; the surface moves; the agent re-observes and adapts; and
when anything breaks, OTP catches it. That combination — a mutable surface over
an unbreakable floor — is what lets the agent be handed a real language, the
right to persist software, and the power to extend its own surface, without any
of it being able to set the house on fire.

---

Back to the [README](README.md) for the full map, or
[overview.md](overview.md) for the mental model that ties it all together.
