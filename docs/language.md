# The language — a computer, not a menu

Substrate hands the agent a **Turing-complete language**, not a list of tools.
The agent writes programs — loops, conditionals, its own helper functions — and
runs them, instead of picking one tool off a menu per turn. This doc covers what
the language is, what's *in* it, what's deliberately *out* of it, and the
distinction between definitions that evaporate and definitions that persist.

The difference from tool-calling is a **vending machine vs a computer**.
Tool-calling is a vending machine: fixed buttons, one purchase at a time.
Substrate is a computer: you *program* it. We only dare hand out a computer
because the sandbox means a bad program can't break anything — **safety is what
unlocks the capability** (see [overview.md](overview.md)).

---

## Why a Lisp

The language leans Lisp/Scheme, and the reason is **homoiconicity** — code and
data have the same shape. That one property buys most of the system's nicest
features for free:

- **code = data = docs.** A capability declaration is an s-expression; so is a
  call to it; so is the agent's own program. The agent reads its action space in
  the *same form* it writes actions. No tool schema to drift from reality (see
  [capabilities.md](capabilities.md)).
- **Static inspection.** Because programs are data, the substrate can inspect an
  emission before running it — validate calls against schemas, analyze structure
  — without executing anything.
- **Clean capability injection.** Capabilities are just symbols resolved in an
  environment. Granting or revoking one is editing a lookup table, not
  recompiling the agent (see [lifecycle.md](lifecycle.md)).

There is a real tension here, and it's an open fork (DESIGN.md fork 1):
**Lisp vs Lua/Luau.** Lisp gives homoiconicity and clean sandboxing, but LLMs
write less of it fluently. Luau is a proven embeddable sandbox and models are
fluent in it — but stock Lua *leaks* (`io`, `os`, `package`) and you lose
homoiconicity. The axis is *safest to sandbox* vs *most fluent for the model*,
and it isn't settled. This doc uses Lisp syntax because the worked examples do.

---

## What's in the language

Everything you need to write real programs over values the agent already holds:

- **Pure computation** — arithmetic, string ops, comparison, the usual.
- **Data structures** — lists, records/maps, keywords. The lingua franca of both
  capability results and the agent's own working data.
- **Control flow** — `let`, `for`, `case`, `cond`, `do`, `break`. Enough to
  express triage loops, retries, and branching on dispositions.
- **Agent-defined functions** — the agent can define its own helpers and call
  them. These are pure, in-sandbox computation; they touch no authority.
- **Capability calls** — the only way to affect the world. Each returns a
  disposition, not a raw value (see [membrane.md](membrane.md)).
- **Introspection** — `describe` reads the live surface as data.
- **Effect handling** — `await` (or the event-inbox equivalent) to resolve a
  queued effect.

A representative emission ties these together:

```lisp
;; One program: triage unread mail, reply to teammates, queue externals.
(let [unread (gmail/search :query "is:unread" :limit 25)]
  (for [m unread]
    (let [reply {:to      (:from m)
                 :subject (str "Re: " (:subject m))
                 :body    (draft-reply m)}]      ; agent-defined, pure helper
      (case (gmail/send reply)
        (:done r)         (log "sent" (:id r))
        (:queued q)       (log "awaiting human" (:handle q))
        (:rate-limited e) (do (log "hit limit; stopping") (break))
        (:denied d)       (log "blocked" (:reason d))))))
```

`draft-reply` is the agent's own function — it computes over values already in
hand and reaches nothing. Defining and calling your own functions inside an
emission is *always* allowed, because it touches nothing.

---

## What's out of the language

This is the part that makes the rest safe. The sandbox has **zero ambient
authority**. None of the following exist as symbols the agent can name — they are
not "blocked by a rule," they have *no referent* in the layer the agent operates
in:

```lisp
(System/getenv "X")    => error: unbound symbol `System/getenv`   ; no env access
(read-file "/etc/x")   => error: unbound symbol `read-file`       ; no filesystem
(http/get "http://…")  => error: unbound symbol `http/get`        ; no raw network
(eval-native "...")    => error: unbound symbol `eval-native`     ; no escape hatch
(gmail/token)          => error: unbound symbol `gmail/token`     ; never existed
```

The exclusions, stated as principles:

- **No environment / config access** — no `os.getenv`, no reading secrets.
- **No filesystem** — nothing to read, write, or traverse.
- **No raw network** — the agent cannot open a socket or make an arbitrary HTTP
  call. The *only* paths to the outside world are governed capabilities.
- **No FFI / eval-to-native** — no escape hatch from the sandbox into L0/L1.
- **No operation that returns a credential** — the token is never a value in the
  agent's world (see [capabilities.md](capabilities.md)).

The guarantee is structural: a fully jailbroken script's *best* outcome is
misusing a capability it was already granted — which is itself rate-clamped and
adjudicated by the membrane. There is no token to steal because there is no
expression that yields one.

---

## Ephemeral vs persisted definitions

The agent defines functions constantly. The question is *how long they live*, and
there are three scopes:

| Scope | Lifetime | Authority | Example |
|---|---|---|---|
| **Within an emission** | one program run | none | a local helper used inside one triage loop |
| **Within a session** | until the session ends | none | a helper defined once, reused across emissions (the "live image") |
| **Persisted to the substrate** | survives the session | governed | a new named capability written into the registry |

The first two are pure computation and **always allowed** — they're the agent's
working memory and toolkit, partly living *in the substrate* rather than only in
its context window (see [harness.md](harness.md)). They touch no authority, so
there's nothing to govern.

The third is the interesting one.

### Can the agent grow the substrate?

Can the agent compose existing capabilities into a *new named capability*,
persist it to the registry, and have it available in future sessions — for
itself or other agents? Growth would be **just another writer to the registry**
(see [lifecycle.md](lifecycle.md)), under the *same enforcement* as any other
capability: a persisted function that calls `gmail/send` is still bounded by
`gmail/send`'s membrane. Composition cannot manufacture authority it wasn't
granted.

The design leans **yes** — that's the version that's actually new: an agent that
extends its own surface, safely, because the floor it's extending is unbreakable
(DESIGN.md fork 5). A persisted definition is governed precisely because it can
outlive the session that wrote it and be reached by others.

---

## The frozen library vs the volatile surface

One more split the language makes (echoing [capabilities.md](capabilities.md)):

- **A frozen standard library** — pure primitives and computation that don't
  move. Build durable towers on it.
- **Volatile capabilities** — anything backed by external authority, governed by
  the membrane and mutable at runtime. Treat as weather; re-check each loop.

Write durable software on the frozen part; write adaptive software against the
volatile part. The language is the same; the *contract* differs, and knowing
which half you're standing on is what keeps the agent's software antifragile
rather than brittle.

---

Next: [lifecycle.md](lifecycle.md) for what "the surface changed" means and how
persisted definitions survive a mutating registry.
