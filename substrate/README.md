# Substrate

> An AI harness where the agent is given a **computer, not a menu of tools** — a
> Turing-complete, sandboxed, live-mutable machine whose I/O is
> capability-secured and whose blast radius is bounded by construction.

This is a working proof-of-concept of the kernel described in
[`../DESIGN.md`](../DESIGN.md) (full write-up in [`../docs/`](../docs/)), with a
**filesystem** capability set as the worked example. It runs.

```bash
mix compile
./demos.sh        # run all the demos, or: ./demos.sh zoned
```

New here as an integrator? **[`INTEGRATION.md`](INTEGRATION.md)** is the
developer's-eye walkthrough: how to load `http` + `fs` onto one surface, bend
them with policy, and hand the result to an LLM — including exactly what the
model sees and what stays behind the wall.

---

## The one idea

**Safety enables capability.** Most agent-safety work *removes* ability — sandbox
the agent so it can do less. Substrate inverts it: make the floor *unbreakable*,
then you can safely hand the agent *more* — a real language, the right to write
and run arbitrary programs. The agent is an **untrusted client** that attaches
from outside the wall and can only express **intent**; a trusted **membrane**
decides if, when, and how that intent becomes an effect.

Two clamps bound the agent on both ends:

- **Input clamp (the capability wall).** The sandbox has *zero ambient
  authority*: no `read-file`, no `System/getenv`, no FFI, no operation that
  returns a credential. The jail root (the secret) is never a value in the
  agent's world — so prompt injection degrades from "steal the secret" to
  "scoped misuse of a capability you were already handed."
- **Effect clamp (the membrane).** Every capability call returns a
  **disposition**, not a raw effect: the membrane can allow, queue for a human,
  rate-clamp, or deny it — fresh, every time.

---

## Architecture

```
L3  Harness    — untrusted reasoner; introspects → writes a program → re-observes
─── membrane   — intent → disposition; adjudication pipeline; human oversight
L2  Substrate  — sandboxed Lisp; capability-secure; self-describing; LIVE surface
L1  Libraries  — native edges, full authority: FS client · HTTP client
L0  Runtime    — Elixir/OTP; the vault — jail root + allowlists, named once
```

| Layer | Module(s) | Trusted? |
|---|---|---|
| **L3 Harness** | your code calling `Substrate.eval/2` | **no** |
| **membrane** | `Substrate.Membrane` | yes |
| **L2 Substrate** | `Substrate.Lisp.{Reader,Eval}`, `Substrate.Server` (registry) | yes |
| **L1 Libraries** | `Substrate.FS`, `Substrate.HTTP` (native edges) | yes |
| **L0 Runtime** | `Substrate.Vault` (jail root + allowlists), OTP | yes |

Several substrates can share one surface: mount `fs` then `http` and an agent
composes across them — `http/get` a file, then `fs/write` it — while every call
still funnels through the same membrane.

The agent only ever touches `Substrate.eval(server, source)`. It hands in
substrate-Lisp and gets back a value — almost always a disposition. It cannot
name, reach, or forge anything else.

---

## The language

A small Lisp (homoiconic: code = data = docs). The agent writes whole programs,
not one tool-call per turn:

```lisp
;; one emission: list a dir, read each file, branch on the disposition
(defn summarize [name]
  (let [r (fs/read :path (string "notes/" name))]
    (case r
      (:done d)   (log name "->" (:bytes d) "bytes")
      (:denied e) (log name "denied"))))
(let [listing (fs/list :path "notes")]
  (case listing
    (:done d)   (for [f (:entries d)] (summarize f))
    (:denied e) (log "cannot list")))
```

**In:** `let` `for` `if` `cond` `case` `do` `fn` `defn` `and` `or` `break`,
agent-defined functions, lists/maps/keywords, arithmetic & string builtins,
`describe` (introspection), `await` (resolve a queued effect), `grant`/`as`
(**delegate** a narrower surface to a sub-task — see below), and capability
calls.

**Out (the wall — these have no referent, not a blocklist):** filesystem access,
env/config, raw network, FFI/eval-to-native, and anything that returns a
credential. Naming one is an unbound-symbol fault.

---

## Capabilities & the substrate

A capability is declared in **one place** — docstring, typed params, return
shape, policy, example, and native binding are a single s-expression
(`priv/substrates/*.lisp`):

```lisp
(capability fs/write
  "Write text to a file, creating parent dirs as needed."
  (parameters (path string "relative to the jail root") (content string))
  (returns (record (bytes integer) (path string)))
  (policy  (deny-if    escapes-jail)
           (rate       "5/min")
           (confirm-if outside-safe))
  (example (fs/write :path "notes/todo.txt" :content "buy milk"))
  (bind    Substrate.FS.write/2))            ; ← native target, STRIPPED at the wall
```

What `(describe fs/write)` returns to the agent is the same declaration **minus
authority and mechanism**: no `bind`, the concrete predicates abstracted
(`confirm-if human-review`). Honest about the outcome, abstract about the cause.

### Dispositions (the syscall errno)

| Disposition | Meaning |
|---|---|
| `(:done {…})` | permitted; the effect ran, result attached |
| `(:queued {:handle …})` | held for a human; `await` it later |
| `(:rate-limited {:retry_after n})` | budget for the window is spent |
| `(:denied {:reason …})` | refused (policy, jail escape, or revoked) |

The name+signature is a **frozen ABI**; the disposition is the **dynamic
errno**. A revoked capability doesn't vanish (that would shatter the agent's
code) — it keeps its signature and returns `:denied`.

### Policy DSL

| Rule | Effect |
|---|---|
| `(deny-if <pred>)` | refuse the call when `<pred>` holds → `:denied` |
| `(confirm-if <pred>)` | route to the human queue when `<pred>` holds → `:queued` |
| `(rate "N/unit")` | clamp to N per `sec`/`min`/`hour`/`day` → `:rate-limited` |
| `(rate "N/unit" <pred>)` | **location-guarded** rate — applies only where `<pred>` holds |

Pipeline order: `revoked? → validate → deny-if → rate → confirm-if → execute`.
Only the last step crosses into native code.

Predicates available (trusted, in `Substrate.Predicates`): `escapes-jail`,
`outside-safe`, `in-bulk`, `in-data`, `in-published`, `in-archive`, and the
two **default-deny allowlists** — `write-denied` (refuse any write outside the
`:fs_allow` dirs) and `host-denied` (refuse any host outside the `:http_allow`
list). Each reads its config from the L0 vault, so the agent can neither read
the allowlist nor name anything off it; an *absent* allowlist denies everything.

---

## The bundled substrates

| Substrate | Demo | Shows |
|---|---|---|
| `dir.lisp` | — | **the simplest substrate** — read + write confined to one directory; nothing escapes the jail |
| `github.lisp` | — | **one self-contained artifact** — `resource` + `secret` + `auth`: authenticated GitHub access where the agent holds no token (load with `Substrate.load/1`) |
| `fs_locked.lisp` | `delegate_demo.exs` | **the agent authors policy** — readable rules (`reveal_rules`), `grant`/`as` attenuated delegation, the audit log |
| `fs.lisp` | `fs_demo.exs` | the full tour: wall, path-jail, code-as-action, confirm-if queue + approve/deny, rate-limit, **live revocation** |
| `archive.lisp` | `archive_demo.exs` | **rate-limited + path-restricted, read-only by construction** (no write capability exists) |
| `spool.lisp` | `spool_demo.exs` | a write capability **capped at 10 files/second** (per-second window resets) |
| `zoned.lisp` | `zoned_demo.exs` | **one `fs/write`, four regimes by location** — bulk unlimited · data rate-limited · published human-approved · archive read-only |
| `http.lisp` + `fs_locked.lisp` | `web_demo.exs` | **surf + download + save, default-deny** — `http/get` reaches only allowlisted hosts, `fs/write` only allowlisted dirs; the demo downloads a real file to disk, then tries (and fails) to reach other hosts, write elsewhere, escape the jail, and exfiltrate |

Run any one: `mix run zoned_demo.exs` (or `./demos.sh zoned`).

---

## Authoring your own

```elixir
{:ok, s} = Substrate.start_link(name: nil)
substrate = "priv/substrates/zoned.lisp" |> File.read!() |> Substrate.read_substrate()

# the jail root is the credential — named exactly once, here, at L0
:ok = Substrate.mount(s, substrate, credentials: %{fs_root: "/some/sandbox"})

Substrate.eval(s, ~s|(fs/write :path "data/x.txt" :content "hi")|)
#=> {:disposition, :"rate-limited", %{retry_after: 41}}   # for example

Substrate.revoke(s, "fs/write")   # live registry write — signature stays, errno flips
```

---

## One artifact: `load`, secrets, authenticated resources

A substrate can carry its own L0 config — an allowlist (`resource`) and a
credential pulled from the environment at load (`secret`) — so the whole sealed
sandbox is **one loadable file** instead of a substrate plus separate mount code.
`Substrate.load/2` resolves the secrets on the trusted side and hands back a
running substrate:

```lisp
(substrate gh
  "Authenticated GitHub access, allowlisted hosts, rate-clamped."
  (resource :http_allow ["api.github.com"])
  (secret   :gh_token   (env "GITHUB_TOKEN"))     ; resolved at load, vaulted
  (capability gh/get
    (parameters (url string "absolute https URL"))
    (returns (record (status integer) (body string) (bytes integer)))
    (auth   (header "Authorization" (string "Bearer " (secret :gh_token))))  ; STRIPPED at the wall
    (policy (deny-if host-denied) (rate "30/min"))
    (bind   Substrate.HTTP.get/2)))
```

```elixir
{:ok, s} = Substrate.load("priv/substrates/github.lisp")   # env → vault → mounted
Substrate.eval(s, ~s|(gh/get :url "https://api.github.com/repos/torvalds/linux")|)
```

The membrane resolves `auth` against the vault microseconds before the socket
and injects the header. The agent emits `(gh/get :url …)` and the call goes out
**authenticated while holding nothing** — `auth`, `secret`, and `bind` are all
stripped at the wall, and no L2 form returns a credential.

## Readable rules (`reveal_rules`)

By default the agent learns a `deny-if` boundary by *hitting* it (honest about
the `:denied`, silent about the rule). Mount with `reveal_rules: true` and
`describe` renders each guard as a **glossed rule the agent can reason about** —
while the **value** stays vaulted:

```elixir
{:ok, s} = Substrate.load("priv/substrates/fs_locked.lisp",
             credentials: %{fs_root: root, fs_allow: ["downloads"]}, reveal_rules: true)

Substrate.eval(s, "(describe fs/write)")
#   (policy (guard "path must stay inside the jail root")
#           (guard "writes limited to allowlisted directories")   ← the RULE, readable
#           (rate "20/min"))                                       ← the VALUE never shown
```

## Delegation: the agent authors a *narrower* policy (`grant` / `as`)

An agent holding authority can carve a **strictly narrower** child surface in
Lisp and run a sub-task inside it. `grant` can only ever *attenuate* — a request
to widen comes back `:denied`:

```lisp
(let [child (grant :caps [fs/write] :fs_allow ["downloads"] :rate "3/min")]
  (as child
    (fs/write :path "downloads/out.txt" :content "written by the sub-agent")))
```

`:caps` ⊆ held capabilities · `:fs_allow`/`:http_allow` ⊆ granted allowlists ·
`:rate` only tightens. The check runs in trusted code (`Substrate.Server.attenuate/2`),
the child is an independent membrane, and `grant` returns an **opaque handle**,
never a credential. The agent authors policy — and can only ever subtract.
(`delegate_demo.exs` walks the whole arc.)

## Observability: the audit log

Every adjudicated call — and every `grant`, including denied widening attempts —
is recorded trusted-side. `Substrate.audit/1` returns the trace (oldest first);
the agent has no L2 path to it:

```elixir
Substrate.audit(s)
#=> [%{seq: 1, cap: "fs/write", outcome: {:done, nil}, at: …},
#    %{seq: 2, cap: "grant",    outcome: {:denied, "cannot widen fs_allow: …"}, …}]
```

---

## Project layout

```
lib/substrate.ex            public API (start_link, mount, load, eval, revoke,
                              approve, attenuate, audit…)
lib/substrate/
  vault.ex                  L0 — the credential store (jail root + allowlists)
  fs.ex                     L1 — native filesystem edge (path-clamped)
  http.ex                   L1 — native HTTP(S) edge (host-allowlisted, auth-injecting)
  auth.ex                   resolve a capability's `auth` template against the vault
  predicates.ex             trusted policy predicates (jail, zones, allowlists)
  capability.ex             compile a substrate (caps + resource/secret/auth);
                              render the stripped `describe` (abstract or revealed)
  membrane.ex               adjudication pipeline → disposition; injects auth
  server.ex                 live registry + rate/queue + audit log + attenuate (GenServer)
  show.ex                   render values back into surface syntax
  lisp/reader.ex            source → s-expression AST
  lisp/eval.ex              the sandboxed evaluator (zero ambient authority; grant/as)
priv/substrates/*.lisp       capability surfaces (dir, fs, archive, spool, zoned,
                              http, fs_locked, github)
*_demo.exs                  runnable demos     demos.sh — run them all
```

## Status

Proof-of-concept. The native edge really touches disk and the network (jailed +
allowlisted); the membrane, disposition model, live registry, capability wall,
policy DSL, in-file secrets/auth (`load`), attenuated delegation (`grant`/`as`),
readable rules (`reveal_rules`), and the audit log are all real. The
human-approval "human" is `Substrate.approve/2` / `deny/2` called from the host;
adjudication is static rules (no LLM monitor yet). See
[`../DESIGN.md`](../DESIGN.md) for the open forks.

Requires Elixir ~> 1.14.
