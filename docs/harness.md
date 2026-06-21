# The harness — attach, loop, wire protocol

The harness is the LLM-driven reasoner. In OS terms it is a **userland process**;
in Substrate terms it is an **untrusted client that attaches to a live
substrate** from outside the trust boundary. The substrate enforces identically
no matter what drives it — Opus, an open-weights model, a swarm of agents, or a
human typing at a REPL.

This doc is the concrete contract: what "attach" means, what crosses the wire,
and what the loop looks like.

---

## Attach

A substrate is a long-lived, stateful process (see [lifecycle.md](lifecycle.md)).
The harness opens a **session** against it:

```
session = attach("brad-inbox-agent")
```

The session is the agent's connection into the kernel. It carries:

- **A view of the surface** — the capabilities currently mounted, as data the
  agent can read (`describe`). The view is *live*: it can change between
  emissions.
- **Session state** — variables the agent defines persist across emissions
  within the session (the "live image" model). The agent's working memory is
  partly *in the substrate*, not only in its context window.
- **An effect inbox** — where dispositions for queued/async effects arrive.

Crucially, the session grants **no authority**. Attaching does not hand over a
token; it hands over the *ability to name capabilities*, nothing more.

---

## The wire protocol

The protocol is a REPL: **the agent sends an s-expression (an *emission*); the
substrate returns values and/or dispositions.** That's the entire contract
between L3 and everything below it.

```
agent  ──emit──▶   (gmail/search :query "is:unread" :limit 5)
substrate ─────▶   (:done [{:id "m1" :from "a@acme.com" :subject "..."} ...])

agent  ──emit──▶   (gmail/send :to "stranger@example.com" :subject "hi" :body "...")
substrate ─────▶   (:queued {:handle eff_42 :reason "external recipient — pending approval"})
```

Three things make this protocol the whole security story:

1. **Everything is an s-expression both ways.** The agent reads its action space
   in the same form it writes actions (code = data = docs). No separate tool
   schema to drift from reality.
2. **The agent can only emit; the substrate disposes.** The agent never receives
   a credential, a file descriptor to the host, or a native reference — only
   values and dispositions.
3. **An emission is the unit of execution and of consistency** (next section).

---

## An emission

A single emission is one program. It can be a one-liner or a hundred lines with
loops, conditionals, and the agent's own helper functions. It runs as **one
supervised process** against a **frozen snapshot** of the surface — so a
capability cannot appear or vanish *mid-emission*. Between emissions, the surface
is free to change.

```lisp
;; One emission: triage unread mail.
(let [unread (gmail/search :query "is:unread" :limit 25)]
  (for [m unread]
    (let [reply {:to (:from m) :subject (str "Re: " (:subject m)) :body (draft-reply m)}]
      (case (gmail/send reply)
        (:done r)         (log "sent" (:id r))
        (:queued q)       (log "awaiting human" (:handle q))
        (:rate-limited e) (do (log "hit limit; stopping") (break))
        (:denied d)       (log "blocked" (:reason d))))))
```

`draft-reply` here is a **pure, in-sandbox helper** the agent defined — no
authority, just computation over values it already has. Defining and calling
your own functions inside an emission is always allowed; it touches nothing.
(Whether such a function can be *persisted* as a new named capability for later
emissions is a policy choice — see [lifecycle.md](lifecycle.md).)

### If an emission crashes

A bad program — infinite loop, exception, nonsense — is isolated and killed by
the supervisor. The agent gets back an error disposition; the substrate is
untouched and the session survives. This is the "can't break itself" isolation:
the agent is free to write broken code because broken code is cheap.

```lisp
(/ 1 0)
=> (:error {:kind :arith :message "division by zero"})   ; session fine, surface fine
```

---

## The loop

The harness loop is **introspect first, act second** — the agent does science on
its own environment before touching it:

```
attach
  │
  ▼
┌─────────────────────────────────────────────┐
│ 1. observe   — read the live surface (describe), read the effect inbox
│ 2. plan      — decide what to do given the surface as it is *right now*
│ 3. emit      — send one s-expression program
│ 4. clamp     — substrate runs it against a snapshot; membrane adjudicates each call
│ 5. observe'  — receive values + dispositions; some effects come back later
└─────────────────────────────────────────────┘
  │
  └──▶ back to 1   (the surface may have changed; re-observe, don't assume)
```

The agent never holds a static model of what it can do. It re-reads the surface
each turn, so a changed surface is not an error condition — it's just the next
observation.

---

## Async dispositions

Some effects don't resolve synchronously — a `:queued` send waits on a human.
Two delivery styles (the choice is still open; see DESIGN.md fork 2):

- **Handle-and-await** — the call returns a handle; the agent can block:
  ```lisp
  (await eff_42)
  => (:done {:id "msg_0190..."})        ; or (:denied {:reason "rejected by brad"})
  ```
- **Event-stream** — the agent moves on; the outcome reappears later as a new
  observation in the effect inbox at the top of a future loop.

Either way the agent only ever learns the *disposition*, never the *mechanism* —
it sees "queued," not "queued because of an external-recipient policy backed by a
human." Honest about the outcome, abstract about the cause.

---

## Why the harness can be anything

Because the harness is outside the wall and holds no authority, you can run *any*
harness against a substrate and the guarantees hold unchanged:

- a frontier model doing careful work,
- a cheap model doing bulk triage,
- a swarm of agents sharing one substrate (see DESIGN.md fork 6),
- a human at a REPL, debugging the same surface the agent sees.

Swap the brain; the kernel doesn't care. That portability is the dividend of
having built the wall at the membrane instead of trusting the reasoner.

---

Next: [membrane.md](membrane.md) for how a call becomes a disposition, or
[lifecycle.md](lifecycle.md) for what "the surface changed" actually means.
