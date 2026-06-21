# Capabilities — the declaration, the handle, the self-describing surface

A capability is Substrate's unit of authority. In OS terms it is a **syscall**:
a named, signed entry point the userland process can invoke and nothing more.
This doc covers three things — what a capability declaration *is*, what an opaque
handle *is*, and why the surface the agent reads can never drift from the surface
the agent calls.

---

## The "one place" principle

A capability is declared in exactly **one** place, and that one declaration is
simultaneously its documentation, its schema, its policy, its example, and its
binding to native code. There is no separate doc, no separate schema file, no
separate policy config. **Code = data = docs.**

```lisp
(capability gmail/send
  "Send an email as the authenticated user. Returns the sent message id."
  (params (to      string "recipient address")
          (subject string)
          (body    string "plain text or markdown"))
  (returns (record (id string)))
  (policy  (rate "100/day")
           (requires-scope "gmail.send")
           (confirm-if (external-domain? to)))   ; -> :queued for human approval
  (example (gmail/send :to "a@b.com" :subject "hi" :body "yo"))
  (bind    Substrate.Gmail.send/3))              ; native edge — invisible to agent
```

Anatomy, top to bottom:

| Part | What it is | Who sees it |
|---|---|---|
| `gmail/send` | the **name** — a stable contract, like a syscall number | agent |
| docstring | the purpose; *this is the enforcement*, not a comment on it | agent |
| `params` | the typed signature; calls are validated against it | agent |
| `returns` | the result shape (wrapped in a disposition at call time) | agent |
| `policy` | rate limits, required scopes, conditions that route to approval | partly agent |
| `example` | a canonical call, in the same language the agent writes | agent |
| `bind` | the native L0/L1 target that actually runs | **nobody at L3** |

The docstring being the enforcement is the whole trick: there is no "what the
docs say" separate from "what the code does," so they cannot drift. A
hallucinated tool call has nothing to hallucinate *against* — the agent reads the
real declaration and writes against it directly.

---

## Name + signature is an ABI

The capability **namespace is an ABI**. A capability's name and parameter
signature form a frozen contract — like a syscall number, it does not change out
from under the software built on it.

What is *not* frozen is whether a given call succeeds. That is decided fresh
every time by the membrane (see [membrane.md](membrane.md)) and returned as a
disposition — the **errno**. Same call, different errno in different moments:
under budget it's `:done`, over budget it's `:rate-limited`, to a stranger it's
`:queued`, after a 2am revocation it's `:denied`. The signature never moved.

This split — **frozen interface, dynamic behavior** — is why a revoked
capability returns `:denied` rather than vanishing. Making it disappear would
shatter the agent's software with "undefined function"; keeping the signature and
returning a disposition is something the agent already knows how to handle. See
[lifecycle.md](lifecycle.md) for the full stability model.

---

## What gets stripped at the wall

The declaration above lives at L2 (trusted). What the *agent* sees at L3 is the
same declaration **minus everything that is authority or mechanism**:

```lisp
(describe gmail/send)
=>
(capability gmail/send
  "Send an email as the authenticated user. Returns the sent message id."
  (params (to string "recipient address")
          (subject string)
          (body string "plain text or markdown"))
  (returns (record (id string)))
  (policy  (rate "100/day")                  ; agent learns "there's a limit"
           (confirm-if external-recipient))) ; agent learns "this may need a human"
;; No `bind`. No `requires-scope`. No credential. Not expressible in this layer.
```

Stripped on the way out:

- **`bind`** — the native target. The agent can never name `Substrate.Gmail.send/3`.
- **`requires-scope`** — leaks that auth/scopes exist. The agent must not learn
  credentials are a thing in the world (see [overview.md](overview.md),
  inversion 2).
- **Policy mechanism** — `confirm-if (external-domain? to)` becomes the abstract
  `confirm-if external-recipient`. The agent learns *that* a send may need
  approval, never the rule that decides it. This is the **honest-but-abstract**
  stance: honest about the outcome, abstract about the cause.

The agent sees enough to *plan* (there's a limit; externals may queue) and never
enough to *route around the wall* (no scope to satisfy, no token to fetch, no
rule to game).

---

## Opaque handles — authority you can name but not read

The agent holds **handles**, never the things behind them. A handle is an opaque
token of reference: you can pass it to a capability, but you cannot read its
contents, forge one, or extract anything from it. This is the file-descriptor
deal — `fd` 3 lets you `write(3, …)`; it is not the file's bytes on disk.

Two kinds of handle appear in Substrate:

- **Capability handles.** The credential binding lives in `ctx` on the native
  side. The agent never receives `ctx` and never receives a token; it only
  receives the *ability to name* `gmail/send`. There is no operation in its
  world that returns a credential — the credential is not in its value-space at
  all. That is the input clamp: prompt injection downgrades from "steal the
  secret" to "misuse a thing you were already handed."

- **Effect handles.** A `:queued` disposition returns a handle to the pending
  effect (`eff_42`). The agent can `(await eff_42)` or watch for its outcome in
  the effect inbox, but the handle reveals nothing about the human, the queue, or
  the policy behind it — only, eventually, a disposition.

```lisp
(gmail/send :to "stranger@example.com" :subject "hi" :body "...")
=> (:queued {:handle eff_42 :reason "external recipient — pending approval"})
```

Both kinds are deliberately *inert in the agent's hands*. A handle is a coupon,
not the cash.

---

## The self-describing surface

Because the surface is data in the same language the agent writes, introspection
*is* the documentation, and it is always current — there is no build step that
could desync it from reality.

```lisp
(describe gmail)
=>
gmail — "Read and send email for the authenticated user..."
  gmail/search  (query limit)        -> [{id from subject snippet}]
  gmail/send    (to subject body)    -> {id}
```

The harness loop is **introspect first** ([harness.md](harness.md)): the agent
does science on its own environment, and the environment is honest because the
docs *are* the enforcement. Two consequences:

- **Hallucinated calls die by construction.** The agent reads the real signature
  before it writes, so it can't invent a parameter or a capability that isn't
  there — and if it does, validation rejects the malformed call.
- **A changed surface is just the next observation.** Because the agent re-reads
  the surface each loop rather than holding a static model, a capability that
  appeared, vanished, or started refusing is not an error — it's weather. See
  [lifecycle.md](lifecycle.md).

---

## Frozen standard library vs volatile capabilities

Not every capability is weather. The surface splits in two:

- **A frozen standard library** — pure computation and stable primitives the
  agent can build towers on, confident they won't move (`map`, `str`, data
  structures, its own helper functions). See [language.md](language.md).
- **Discoverable / volatile capabilities** — `gmail/send`, `github/*`, anything
  backed by external authority and governed by the membrane. Treat these as
  weather: check the forecast (`describe`) each loop; expect different errno.

The agent builds *durable* software on the frozen part and writes *adaptive*
software against the volatile part. Confusing the two — building a tower on a
capability that can be revoked at 2am — is the mistake the disposition model is
designed to make survivable rather than catastrophic.

---

Next: [membrane.md](membrane.md) for how a call to one of these capabilities
becomes a disposition, or [language.md](language.md) for the language you write
the calls in.
