# The membrane — intent becomes (or doesn't become) effect

The capability wall ([capabilities.md](capabilities.md)) is the *input* clamp:
the agent can't reach authority. The membrane is the *effect* clamp: the agent
can't unilaterally act. Every capability call passes through it, and what comes
back is not a value but a **disposition** — the kernel's verdict on the agent's
intent.

In OS terms the membrane is the **permission check in the syscall path**. The
novelty is who gets to sit in that path: not only static rules, but security
software, *other agents*, and *humans* — adjudicating intent in real time.

---

## A capability returns a disposition, not a value

The agent expresses **intent**; the membrane is the **reality principle** that
decides if, when, and how intent becomes effect. There are four dispositions:

| Disposition | Meaning | HTTP analogue |
|---|---|---|
| `(:done result)` | the effect happened; here's the result | `200 OK` |
| `(:queued {:handle …})` | pending approval; here's a handle to it | `202 Accepted` |
| `(:rate-limited {:retry-after …})` | over budget; back off | `429 Too Many Requests` |
| `(:denied {:reason …})` | refused; the signature still exists | `403 Forbidden` |

The agent already knows this shape — it's status codes. Every program that talks
to a network handles "submitted, outcome later." The agent just programs against
the disposition:

```lisp
(case (gmail/send reply)
  (:done r)         (log "sent" (:id r))
  (:queued q)       (log "awaiting human" (:handle q))
  (:rate-limited e) (do (log "hit limit; stopping") (break))
  (:denied d)       (log "blocked" (:reason d)))
```

Crucially, `:denied` does **not** mean the capability vanished. The name and
signature are a frozen ABI ([capabilities.md](capabilities.md)); `:denied` is
just this moment's errno. Same call, later, may return `:done`.

---

## The adjudication pipeline

What *decides* the disposition is a **pluggable pipeline**, composed per
capability. Each stage can pass the call along, transform it, or short-circuit
with a disposition. The stages range from trivial to intelligent:

- **Static rules** — rate limits, scope checks, allow/deny lists. Pure functions,
  effectively free.
- **Security software** — a scanner inspecting the call's arguments for
  exfiltration patterns, injected payloads, anomalies.
- **A monitoring agent** — *another* LLM watching the proposing agent's behavior
  and ruling on borderline calls.
- **A human** — sitting directly in the path via the approval queue.

A capability wires its pipeline when it's mounted (see [gmail.md](gmail.md)):

```elixir
adjudicators: [
  Substrate.Adjudicator.RateLimit,                               # static, ~free
  Substrate.Adjudicator.ApprovalQueue,                           # serves confirm-if -> :queued
  {Substrate.Adjudicator.MonitorAgent, model: "claude-haiku-4-5"} # slow-path stream watcher
]
```

### Tiered adjudication — you can't run an LLM on every call

Intelligence is expensive; most calls are boring. So the pipeline is **tiered**:
cheap static rules fast-path the ~99% of calls that are obviously fine, and only
*flagged* calls escalate to an agent or a human. The ordering above is the
ordering by cost — free checks first, the LLM monitor last, the human last of
all. A call that the RateLimit and ApprovalQueue stages clear never wakes the
expensive stages at all.

This is what keeps the membrane from becoming a latency tax on every emission
while still allowing genuinely intelligent oversight where it's warranted.

---

## The approval queue

The most important slow-path stage. When a capability's `policy` includes a
`confirm-if` condition that fires, the ApprovalQueue adjudicator short-circuits
the call into `:queued`, returns a handle, and **holds the effect** — nothing has
happened in the world yet.

```lisp
(gmail/send :to "stranger@example.com" :subject "hi" :body "...")
=> (:queued {:handle eff_42 :reason "external recipient — pending approval"})
```

On the trusted side, the queued effect surfaces to whoever the queue routes to —
a human in a UI, or a monitoring agent. When they rule, the disposition resolves:

```lisp
(await eff_42)
=> (:done   {:id "msg_0190..."})            ; brad approved
;; or
=> (:denied {:reason "rejected by brad@rocketship.io"})
```

The agent learns *that* the send queued and, eventually, the outcome — never the
mechanism (it never learns auth or a human exists). Honest about the outcome,
abstract about the cause. Whether the agent blocks on `(await …)` or receives the
outcome later as a new observation in its effect inbox is an open delivery
question (DESIGN.md fork 2; see [harness.md](harness.md)).

---

## Proposer / disposer — two minds, one wall

The architecture's defining move is a **split of judgment**:

- The untrusted L3 actor only ever **proposes**. It is fast, creative, and
  allowed to be reckless.
- The trusted intelligence lives *in the membrane* and **disposes**. It is slow,
  skeptical, and adjudicates.

Two minds on opposite sides of one wall. This is unlike LangGraph or a raw API
loop, where reasoner and tools are *fused* into one trusted process and the
model's own judgment *is* the security boundary. Substrate *splits* them at the
membrane and demotes the reasoner to an untrusted client. **The wall is what lets
the actor be reckless** — because nothing the proposer proposes becomes real
without the disposer's say-so.

The proposer can attach a **rationale** to a call — a short justification — so
the disposer can reason about *intent*, not just inspect arguments:

```lisp
(gmail/send :to "stranger@example.com" :subject "refund" :body "..."
            :rationale "customer #8821 requested refund confirmation in ticket T-4490")
```

A monitor agent reads the rationale alongside the call and rules with context the
arguments alone wouldn't carry.

---

## Oversight is behavioral, not just per-call

A static rule sees one call. An adjudicating *agent* can watch the **stream** of
the proposer's behavior and rule on the pattern:

> "40 borderline emails this hour → clamp."

This is fraud detection on the agent's own actions. A call that passes every
per-call check in isolation can still be the 41st in a suspicious burst, and a
behavioral adjudicator can route it to `:queued` or `:denied` on those grounds
alone. Per-call checks bound *what* a single action can do; behavioral oversight
bounds *what a campaign of actions* can do.

---

## Bounded watchers — the overseer can't be subverted either

If the monitor is itself an agent, what stops *it* from being compromised? The
monitor agent is itself a **substrate harness** — capability-limited, behind its
own wall, holding no authority it doesn't need. The overseer is sandboxed by the
same construction as the actor it oversees. There is no privileged, ambient,
all-powerful watcher to subvert; there is only another bounded process with a
narrower surface.

---

## The membrane, summarized

```
agent emits intent  ──▶  ┌─────────── membrane ───────────┐  ──▶  effect (maybe)
                         │ static rules   (free, ~99%)     │
                         │ security scan  (flagged calls)  │
                         │ monitor agent  (behavioral)     │
                         │ human queue    (confirm-if)     │
                         └────────────────────────────────┘
                                       │
                              disposition back to agent
                         (:done / :queued / :rate-limited / :denied)
```

The agent proposes into the top and reads a disposition off the bottom. Whether
its intent crossed into reality — and what it cost — is decided in between, by
whatever mix of rule, software, agent, and human the capability's authors wired
up. The agent never sees the machinery; it only programs against the verdict.

---

Next: [language.md](language.md) for the language intent is expressed in, or
[lifecycle.md](lifecycle.md) for what happens to a queued effect when the
capability behind it is revoked mid-flight.
