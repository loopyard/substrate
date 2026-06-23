# Gmail on Substrate — author it, then call it

Two audiences, two halves:

1. **Authoring** (a developer, once) — define the Gmail capabilities, bind them
   to native code, mount them with a credential. Lives across L0/L1/L2.
2. **Calling** (the agent, every loop) — introspect the surface and emit
   substrate code. Lives entirely in L3, behind the wall.

The whole point: the second half *cannot reach* anything from the first half
except the capability handles it was granted.

---

## Part 1 — Authoring the Gmail substrate

### 1a. The native edge (L1) — full authority, never reachable from L2

This is ordinary Elixir. It holds the token; it runs *inside* the trust
boundary. The agent can never name, call, or see this module.

```elixir
defmodule Substrate.Gmail do
  @moduledoc "Native Gmail client. L1 — full authority. Invisible to the harness."

  # `ctx` carries the L0-minted credential handle. The agent cannot construct,
  # forge, or read it — it only exists on this side of the membrane.
  def search(ctx, %{query: q, limit: limit}) do
    token = Substrate.Vault.fetch!(ctx, :gmail)        # token lives in L0
    GmailAPI.list_messages(token, q, limit)
  end

  def send(ctx, %{to: to, subject: subject, body: body}) do
    token = Substrate.Vault.fetch!(ctx, :gmail)
    GmailAPI.send_message(token, to, subject, body)
  end
end
```

### 1b. The capability substrate (L2) — code = data = docs, "in one place"

This is the heart. Each capability's purpose, params, return shape, policy,
example, and native binding are **one declaration**. The docstring *is* the
enforcement; they cannot drift.

```lisp
(substrate gmail
  "Read and send email for the authenticated user. All sends are governed:
   external recipients route to a human approval queue; volume is rate-clamped."

  (capability gmail/search
    "Search the user's mailbox. Returns a list of message summaries."
    (params (query string "Gmail search syntax, e.g. \"from:boss is:unread\"")
            (limit (int :default 20 :max 100)))
    (returns (list (record (id string) (from string)
                           (subject string) (snippet string))))
    (policy  (rate "1000/day"))
    (example (gmail/search :query "is:unread from:stripe.com" :limit 10))
    (bind    Substrate.Gmail.search/2))           ; <- L0-only. Stripped from the surface.

  (capability gmail/send
    "Send an email as the authenticated user. Returns the sent message id."
    (params (to      string "recipient address")
            (subject string)
            (body    string "plain text or markdown"))
    (returns (record (id string)))
    (policy  (rate "100/day")
             (requires-scope "gmail.send")
             (confirm-if (external-domain? to)))   ; -> :queued for human approval
    (example (gmail/send :to "teammate@acme.com" :subject "ship it" :body "merged"))
    (bind    Substrate.Gmail.send/3)))             ; <- L0-only. Stripped from the surface.
```

### 1c. Mount it — bind the credential at L0, attach adjudicators

The token is *named exactly once*, here, in trusted code. This is also where the
membrane's adjudication pipeline is wired.

```elixir
{:ok, sub} = Substrate.start_link(name: "brad-inbox-agent")

Substrate.mount(sub, Substrate.Gmail,
  # The ONLY place the credential is named. Never crosses into L2.
  credentials: %{gmail: Substrate.Vault.oauth(:gmail, user: "brad@rocketship.io")},

  # The adjudication pipeline — fast/cheap first, expensive/intelligent last.
  adjudicators: [
    Substrate.Adjudicator.RateLimit,                       # static, ~free
    Substrate.Adjudicator.ApprovalQueue,                   # serves confirm-if -> :queued
    {Substrate.Adjudicator.MonitorAgent, model: "claude-haiku-4-5"}  # slow-path stream watcher
  ])
```

Now `gmail/*` is live in this substrate's registry. Mounting another substrate,
or revoking this one, is a runtime registry write — the surface changes under
the agent without restarting it.

---

## Part 2 — Calling it from the harness

The agent attaches from outside the wall. Its first move is **introspection**,
not action.

### 2a. Discover the surface (`describe`)

```lisp
(describe gmail)
=>
gmail — "Read and send email for the authenticated user..."
  gmail/search  (query limit)        -> [{id from subject snippet}]
  gmail/send    (to subject body)    -> {id}
```

Drill into one. Note what comes back is the **same declaration minus the secret
parts** — no `bind`, no `requires-scope`, policy abstracted (honest-but-abstract):

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

### 2b. Call it — every call returns a *disposition*

Happy path:

```lisp
(gmail/send :to "teammate@acme.com" :subject "ship it" :body "merged")
=> (:done {:id "msg_018f3a..."})
```

External recipient → the membrane intercepts, no effect yet:

```lisp
(gmail/send :to "stranger@example.com" :subject "hi" :body "...")
=> (:queued {:handle eff_42
             :reason "external recipient — pending human approval"})
```

Over budget:

```lisp
(gmail/send :to "teammate@acme.com" :subject "..." :body "...")
=> (:rate-limited {:retry-after 3600})
```

### 2c. Code-as-action — the agent writes a *program*, not one call

This is the leap over tool-calling: one emission, with control flow, that the
substrate clamps the whole way through. It runs as a single supervised process
against a **snapshot** of the surface.

```lisp
;; Triage unread mail: reply to teammates, let externals queue for approval,
;; stop cleanly if we hit the send limit.
(let [unread (gmail/search :query "is:unread" :limit 25)]
  (for [m unread]
    (let [reply {:to      (:from m)
                 :subject (str "Re: " (:subject m))
                 :body    (draft-reply m)}]          ; pure, in-sandbox helper
      (case (gmail/send reply)
        (:done r)         (log "sent" (:id r))
        (:queued q)       (log "awaiting human" (:handle q))
        (:rate-limited e) (do (log "hit daily limit; stopping") (break))
        (:denied d)       (log "blocked" (:reason d))))))
```

Same ABI, different errno per call. The agent never learns *why* a send queued
or denied — only that it did, so it can adapt.

### 2d. (Optional) await a queued effect

If the harness wants synchronous flow, it can block on the handle until the
human — or a monitor agent — rules. *(Fork 2 in DESIGN.md: handle-and-await vs
pure event-stream is still undecided; shown here as handle-and-await.)*

```lisp
(await eff_42)
=> (:done   {:id "msg_0190bb..."})                 ; brad approved
;; or
=> (:denied {:reason "rejected by brad@rocketship.io"})
```

---

## Part 3 — What the agent *cannot* do (the wall, demonstrated)

None of these are "blocked by a rule." They simply have no referent in the
layer the agent operates in:

```lisp
(gmail/token)          => error: unbound symbol `gmail/token`     ; never existed
(:token gmail)         => error: `gmail` is a namespace, not a value to destructure
(System/getenv "X")    => error: unbound symbol `System/getenv`   ; no ambient authority
(read-file "/etc/x")   => error: unbound symbol `read-file`       ; no filesystem
(eval-native "...")    => error: unbound symbol `eval-native`     ; no escape hatch
```

A fully jailbroken script's *best* outcome is misusing `gmail/send` — which is
rate-clamped and routes externals to a human. It cannot obtain the token to use
anywhere else, because the token was never a value in its world.

---

## Part 4 — The same call, governed differently over time

Because the surface is live and adjudication is contextual, the *identical*
emission yields different dispositions as policy or behavior changes — with the
signature frozen the whole time (ABI stable, errno dynamic):

| Moment | `(gmail/send :to "x@acme.com" ...)` returns | Decided by |
|---|---|---|
| normal | `(:done {...})` | fast-path, no adjudicator fires |
| 101st send today | `(:rate-limited {:retry-after ...})` | RateLimit |
| to an external domain | `(:queued {:handle ...})` | ApprovalQueue (confirm-if) |
| 40 borderline sends this hour | `(:queued ...)` or `(:denied ...)` | MonitorAgent (behavioral) |
| brad revokes Gmail at 2am | `(:denied {:reason "capability suspended"})` | registry write — *signature still exists* |

The agent's triage program in 2c keeps running across all of these. It never
breaks; it just sees different errno and adapts.
