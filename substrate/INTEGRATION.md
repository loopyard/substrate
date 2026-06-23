# Wiring substrates together — and handing them to an LLM

This is the developer's-eye (and model's-eye) view of putting a substrate
together: load **two** substrates (`http` + `fs`) onto one surface, bend them
with **policy**, and hand the result to an LLM. Three actors, one wall:

```
         TRUSTED (you, the developer)                  UNTRUSTED (the LLM)
  ┌───────────────────────────────────────┐        ┌──────────────────────┐
  │ L0  mint the vault: jail root +        │        │  reads (describe)    │
  │     allowlists  (the secrets)          │        │  emits a program     │
  │ L2  mount manifests: the capabilities  │  wall  │  reads the           │
  │     + which policy RULES apply         │ ─────► │     disposition      │
  └───────────────────────────────────────┘        │  reacts, loops       │
                  the membrane adjudicates ─────────└──────────────────────┘
                  every call → a disposition
```

The LLM only ever touches **one function**: `Substrate.eval(server, source)`. It
cannot name the jail root, read an allowlist, or call anything else. Everything
below is what *you* do on the trusted side, and what the *model* sees through the
wall.

---

## Act 1 — Assemble: two substrates, one surface

A "substrate" is a manifest (`priv/manifests/*.lisp`) plus the native edge it
binds to. You `mount` each onto one running server; they share a wall and a
membrane.

```elixir
# A sandbox dir on the real disk, with two subdirs we'll allow writes into.
root = "/tmp/agent_jail"
File.mkdir_p!(Path.join(root, "downloads"))
File.mkdir_p!(Path.join(root, "cache"))

# One server = one surface = one membrane.
{:ok, s} = Substrate.start_link(name: nil)

# Parse the two manifests…
fs   = "priv/manifests/fs_locked.lisp" |> File.read!() |> Substrate.read_manifest()
http = "priv/manifests/http.lisp"      |> File.read!() |> Substrate.read_manifest()

# …and mount them. Each mount adds a namespace AND binds that substrate's
# L0 secrets. Mounting twice composes — it does not replace.
:ok = Substrate.mount(s, fs,   credentials: %{fs_root: root, fs_allow: ["downloads", "cache"]})
:ok = Substrate.mount(s, http, credentials: %{http_allow: ["example.com", "raw.githubusercontent.com"]})
```

That's it. The agent can now `http/get` a file and `fs/write` it — composed in a
single program — and nothing else. The `fs` and `http` namespaces sit side by
side on the same surface.

---

## Act 2 — Policy: a rule (in the manifest) + a value (at L0)

This is the part worth internalizing. **Policy is two halves, and they live in
two different places:**

| Half | Where it lives | Who writes it | Example |
|---|---|---|---|
| **The rule** — *that* writes are allowlist-gated | the manifest `policy` block, by predicate name | the substrate author | `(deny-if write-denied)` |
| **The value** — *which* dirs/hosts are on the list | the L0 `credentials` at mount | you, the integrator | `fs_allow: ["downloads", "cache"]` |

So the manifest says **"deny writes outside the allowlist"**; your `mount` call
says **"…and the allowlist is `downloads/` and `cache/`."** The same manifest,
mounted with different credentials, is a different policy — *no code change*:

```elixir
# Strict: writes only into downloads/
mount(s, fs, credentials: %{fs_root: root, fs_allow: ["downloads"]})

# Looser: also allow cache/ and tmp/
mount(s, fs, credentials: %{fs_root: root, fs_allow: ["downloads", "cache", "tmp"]})

# Locked shut: no fs_allow at all → DENY-ALL, every write refused.
mount(s, fs, credentials: %{fs_root: root})
```

**Default-deny is structural.** The allowlist predicates (`write-denied`,
`host-denied`) refuse anything not explicitly listed, and an *absent* list
refuses everything. Opening a hole is an L0 act — adding an entry to the vault —
never something the agent can do from inside.

Here are the two manifests' policy blocks as written (the rules), and the
credentials that fill them (the values):

```lisp
;; fs_locked.lisp — the RULES
(capability fs/write
  (policy (deny-if escapes-jail)      ; can't leave the jail, ever
          (deny-if write-denied)      ; …or write outside the allowlist
          (rate    "20/min")))        ; …or write faster than 20/min
```
```lisp
;; http.lisp — the RULES
(capability http/get
  (policy (deny-if host-denied)       ; can't reach a non-allowlisted host
          (rate    "10/min")))        ; …or GET faster than 10/min
```
```elixir
# your mount — the VALUES that make those rules concrete
credentials: %{
  fs_root:    "/tmp/agent_jail",                          # the jail (a secret)
  fs_allow:   ["downloads", "cache"],                     # write-denied checks this
  http_allow: ["example.com", "raw.githubusercontent.com"] # host-denied checks this
}
```

The predicate names (`write-denied`, `host-denied`, `escapes-jail`, `rate`) are
the vocabulary; see the README's **Policy DSL** for the full set.

---

## Act 3 — Offer it to the LLM

The model's entire action space is: **emit substrate-Lisp, read the
disposition.** You give it two things — the *surface* (so it knows what exists)
and the *eval seam* (so it can act).

### What the LLM reads: `(describe)`

This string goes straight into the model's context. It is the **real** output of
`Substrate.eval(s, "(describe)")` for the surface assembled above:

```
fs — "Jailed filesystem access with default-deny writes. Reads stay inside the jail
   root; writes are refused unless the target sits inside an allowlisted
   directory. Nothing can escape the jail."
  fs/list  (path)  -> (record (entries (list string)))
  fs/read  (path)  -> (record (content string) (bytes int))
  fs/write  (path content)  -> (record (bytes int) (path string))

http — "Make outbound HTTP(S) GET requests, restricted to an allowlisted set of hosts.
   Default-deny: a request to any host not explicitly allowed is refused. Use the
   returned :body together with the fs substrate to save a download to disk."
  http/get  (url)  -> (record (status int) (body string) (bytes int))
```

It can drill in. `(describe fs/write)` returns:

```
(capability fs/write
  "Write text to a file. DENIED unless the target is inside an allowlisted
     directory; volume is rate-clamped."
  (params (path string "...") (content string "..."))
  (returns (record (bytes int) (path string)))
  (policy (rate "20/min")))
```

> **Honest, but abstract.** Look at that `policy` block: it shows the **rate**,
> but the two `deny-if` rules are *gone*. The model is told it can be
> rate-limited; it is **not** told the allowlist exists or what's on it. It
> learns the boundary the way a process learns a permission error — by making
> the call and reading `:denied`. The docstring hints ("DENIED unless …
> allowlisted directory"); the machine-readable rule does not. The credential
> and the allowlist never cross the wall.

### What the LLM does: emit a program, read the disposition

One turn. The model writes a whole program (control flow included), you `eval`
it, and you hand back the rendered disposition:

```elixir
# `source` is whatever the model emitted this turn.
source = ~S"""
(let [r (http/get :url "https://example.com")]
  (case r
    (:done d)   (fs/write :path "downloads/example.html" :content (:body d))
    (:denied e) (log "fetch blocked")))
"""

result = Substrate.eval(s, source)
#=> {:disposition, :done, %{bytes: 559, path: "downloads/example.html"}}

# Render it back into the surface syntax the model already understands,
# and feed it in as the result of its action.
Substrate.Show.form(result)
#=> "(:done {:bytes 559 :path \"downloads/example.html\"})"
```

If the model aims off the allowlist, the *same seam* hands back a refusal it can
read and recover from — no exception, no secret leaked:

```elixir
Substrate.eval(s, ~S|(http/get :url "https://api.github.com/user")|)
#=> {:disposition, :denied, %{reason: "denied by policy"}}    # host not allowlisted

Substrate.eval(s, ~S|(fs/write :path "secrets/k.txt" :content "x")|)
#=> {:disposition, :denied, %{reason: "denied by policy"}}    # dir not allowlisted

Substrate.eval(s, ~S|(System/cmd "curl" "evil.example")|)
#=> {:fault, "unbound symbol `System/cmd`  (no such capability — `(describe)` the surface)"}
```

### Presenting it as the model's tool

In an actual LLM loop the offering is one tool with one argument. The shape:

```
SYSTEM:
  You drive a sandboxed computer by emitting programs in a small Lisp.
  Your available surface is:

  <paste the (describe) output here>

  Each call returns a disposition, never a raw value:
    (:done {...})         it ran; result attached
    (:queued {:handle h}) held for a human; (await h) later
    (:rate-limited {...}) slow down; :retry_after seconds
    (:denied {...})       refused; read the reason and adapt
  A fault means your *code* was wrong (e.g. a name that doesn't exist).

TOOL  substrate_eval(source: string)
  → runs `Substrate.eval(server, source)`, returns `Show.form(result)`
```

The model never sees `mount`, `credentials`, `fs_root`, or the allowlists. Its
whole world is the `(describe)` surface and the dispositions that come back. The
policy you set in Act 2 is enforced on every call without the model ever being
able to see — let alone change — the rules.

---

## The whole thing, end to end

```elixir
# ── TRUSTED: assemble + set policy (Acts 1–2) ───────────────────────────────
root = "/tmp/agent_jail"
File.mkdir_p!(Path.join(root, "downloads"))

{:ok, s} = Substrate.start_link(name: nil)
fs   = "priv/manifests/fs_locked.lisp" |> File.read!() |> Substrate.read_manifest()
http = "priv/manifests/http.lisp"      |> File.read!() |> Substrate.read_manifest()
:ok  = Substrate.mount(s, fs,   credentials: %{fs_root: root, fs_allow: ["downloads"]})
:ok  = Substrate.mount(s, http, credentials: %{http_allow: ["raw.githubusercontent.com"]})

# ── UNTRUSTED: the LLM's world is just these two calls (Act 3) ───────────────
surface = Substrate.eval(s, "(describe)")          # → into the model's context
# … model emits `source` …
reply   = Substrate.Show.form(Substrate.eval(s, source))  # → back to the model
```

`Substrate.Harness` (see `lib/substrate/harness.ex`) is a reference
implementation of that untrusted loop — `observe`, `discover`, `pursue` — built
entirely on `eval/2`, which is the proof that the *seam*, not the harness, is
what's trusted.
