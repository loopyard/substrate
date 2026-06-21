# Overview — the mental model

Substrate feels weird because nearly every property inverts how agents are built
today. But there's one model that makes all of it ordinary, because we've been
living with it for fifty years:

> **Substrate is an operating system. The agent is a userland process.**

That's the whole thing. Hold it, and each weird property becomes a familiar OS
property aimed at an LLM:

| Substrate | Operating system |
|---|---|
| The agent (harness) | a userland process |
| A capability (`gmail/send`) | a syscall (`write`) |
| A disposition (`:queued`, `:denied`) | `errno` (`EAGAIN`, `EACCES`) |
| The membrane | the kernel's permission check |
| Capability handles | file descriptors (opaque ints, not the file) |
| The substrate runtime (L0/L1/L2) | the kernel |
| A human approver | a kernel sitting in the syscall path |

A process can do anything *it has a descriptor for*, and nothing else. It never
sees the disk, the page tables, or root's password. It calls `write(fd, …)` and
gets back success or `errno`. That is exactly the deal the agent gets — we've
just never given the "process" an LLM for a brain before.

---

## The five inversions, made ordinary

### 1. "The reasoner is *untrusted*."

Today the model's judgment *is* the security boundary — the loop and the
`GITHUB_TOKEN` live in one process. In Substrate the agent runs in userland; the
kernel doesn't trust it.

**You already use this.** A web page runs untrusted JavaScript. It can do
anything *inside* the tab and nothing to your filesystem. Substrate is the
browser sandbox, for agents. The agent is the page; the substrate is the
browser.

### 2. "The agent doesn't know credentials *exist*."

It never hunts for an API key, never reads `.env`, never social-engineers a
secret — because it has no concept that secrets are a thing in the world.

**You already use this.** An HttpOnly cookie: your JavaScript calls
`fetch('/api')`, the browser attaches the cookie, and the script can *never read
it*. Substrate generalizes HttpOnly to *all* authority. The credential is
attached on the far side of a wall the agent can't see across.

### 3. "You hand it a whole *language*, not a list of tools."

The agent writes Turing-complete programs — loops, conditionals, its own helper
functions — and runs them, instead of picking one tool off a menu per turn.

**The difference is a vending machine vs a computer.** Tool-calling is a vending
machine: fixed buttons, one purchase at a time. Substrate is a computer: you
*program* it. We only dare hand out a computer because the sandbox means a bad
program can't break anything. *Safety is what unlocks the capability* — see
"safety, not stability" below.

### 4. "The agent's abilities change *while it runs*."

Capabilities appear, vanish, or start refusing — mid-task, without restarting
the agent.

**You already use this.** Syscalls. A device gets unplugged, a permission gets
revoked, the kernel gets patched — your program doesn't crash, it gets an error
from the next call and copes. The agent is a long-running program against a live
kernel. It re-checks its surface each loop and routes around what changed.

### 5. "A capability returns a *disposition*, not a value."

`gmail/send` doesn't return "sent." It returns one of `:done`, `:queued`
(pending a human), `:rate-limited`, `:denied`.

**You already use this.** HTTP: `200 OK`, `202 Accepted` (queued), `429 Too Many
Requests`, `403 Forbidden`. Every program that talks to a network already
handles "submitted, outcome later." The agent just programs against status
codes.

---

## The two walls

The OS analogy also explains *why it's safe*. The agent is clamped on both ends:

- **Input wall (no authority to steal).** Like a process that holds a file
  descriptor but never the file's bytes on disk, the agent holds *opaque
  capability handles* but never a credential. There is no operation in its world
  that returns a token. Prompt injection downgrades from "steal the secret" to
  "misuse a thing you were already handed" — and that misuse is itself clamped
  by the second wall.

- **Effect wall (no unilateral action).** Like a syscall that the kernel can
  reject, throttle, or route through a permission prompt, every capability call
  passes through the **membrane** before it becomes a real-world effect. The
  agent expresses *intent*; the membrane is the *reality principle* that decides
  if, when, and how intent becomes effect — and a human (or a monitoring agent)
  can sit right in that path.

The novel part is who sits in the kernel: not just static rules, but **humans
and other agents**, adjudicating intent. The membrane is where an untrusted,
creative *actor* and a trusted, skeptical *adjudicator* meet — two minds on
opposite sides of one wall. The wall is what lets the actor be reckless.

---

## Safety, not stability — the contract

A normal OS promises your program a *stable ABI*: `write()` will keep working.
Substrate splits that promise in two, and this is the part with no exact OS
analogue:

- **The interface is stable** — a capability's name and signature is a frozen
  contract, like a syscall number. Software the agent builds keeps its shape.
- **The behavior is not** — *whether* a call succeeds is decided fresh every
  time by the membrane. Same call, different `errno`, depending on rate,
  recipient, policy, the agent's recent behavior, or a 2am revocation.

So Substrate does **not** promise "your code keeps working." It promises
something stranger and stronger: **"when your code breaks, nothing catches
fire."** A program built on a capability that got revoked simply fails its next
call, gets supervised (crash → isolate → restart, the OTP way), and the agent
re-observes and rebuilds. The property is **antifragility, not stability** — the
agent can always rebuild without burning down the house.

That inverted contract is the thesis in one line:

> **Make the floor unbreakable, and you can safely hand the agent far more** — a
> real language, the right to write and persist software, even the power to
> extend its own surface. You can only give a process root-free freedom because
> the kernel holds the dangerous things. Substrate is that kernel, for agents.

---

Next: [architecture.md](architecture.md) for the five layers in detail, or
[harness.md](harness.md) to see an agent actually attach and run.
