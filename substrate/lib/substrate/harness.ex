defmodule Substrate.Harness do
  @moduledoc """
  A reference **L3 harness** — the untrusted code that *drives* a substrate from
  outside the wall. It is the worked answer to "what does the agent's host loop
  actually look like?"

  The whole module obeys one rule: it touches **only** `Substrate.eval/2`. It
  never names the credential, never calls `approve`/`deny`/`revoke`, never
  reaches past the eval seam — those are the trusted host's, not the agent's.
  All it can do is *introspect the surface*, *emit a program*, and *react to the
  disposition* that comes back. That reaction loop is the entire point: a
  tool-calling agent gets a value or an exception; a substrate agent gets a
  **disposition** (`:done` · `:queued` · `:rate-limited` · `:denied`) plus the
  possibility of its own code faulting, and must decide what to do next.

  Nothing here is privileged. You could paste `observe/2`, `discover/2`, and
  `pursue/3` into any client of `Substrate.eval/2` and they would behave
  identically — which is the proof that the seam, not the code, is what's
  trusted.
  """

  @typedoc """
  The normalized outcome of one emission. Every raw `eval` return collapses to
  one of these so the host loop can branch on a flat tag:

    * `{:done, payload}`          — the effect ran; result map attached
    * `{:queued, %{handle: h}}`   — held for a human; resolve via `(await h)`
    * `{:"rate-limited", %{...}}` — budget spent; `:retry_after` seconds attached
    * `{:denied, %{reason: r}}`   — the membrane refused
    * `{:fault, msg}`             — the *agent's own code* was bad (caught at L2)
    * `{:text, str}`              — a `describe` surface render
    * `{:value, term}`            — a plain value (arithmetic, a list, …)
  """
  @type outcome ::
          {:done | :queued | :"rate-limited" | :denied, map()}
          | {:fault, String.t()}
          | {:text, String.t()}
          | {:value, term()}

  @doc """
  Emit one program and normalize whatever `eval` hands back into an `outcome`.
  This is the single primitive every other function is built on.
  """
  @spec observe(GenServer.server(), String.t()) :: outcome
  def observe(server, program) do
    case Substrate.eval(server, program) do
      {:disposition, tag, payload} -> {tag, payload}
      {:fault, msg} -> {:fault, msg}
      text when is_binary(text) -> {:text, text}
      other -> {:value, other}
    end
  end

  @doc """
  Introspect the live surface — the agent's first move on attaching, and its way
  back to ground truth whenever a `:fault` says it imagined a capability. Returns
  the `describe` render verbatim (the same Lisp the agent writes), with the
  credential and native bindings already stripped by the membrane.
  """
  @spec discover(GenServer.server(), String.t() | nil) :: String.t()
  def discover(server, target \\ nil) do
    query = if target, do: "(describe #{target})", else: "(describe)"
    {:text, text} = observe(server, query)
    text
  end

  @doc """
  The capability names currently on the surface, parsed out of the namespace
  render. Lets the harness *plan against what exists now* rather than against a
  baked-in list — capabilities are live data, so a revoke between turns really
  does change this.
  """
  @spec capabilities(GenServer.server()) :: [String.t()]
  def capabilities(server) do
    server
    |> discover()
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^\s+(\S+\/\S+)/, line) do
        [_, name] -> [name]
        _ -> []
      end
    end)
  end

  @doc """
  Pursue one intent and see it through to a *terminal* disposition.

  The interesting case is `:queued`: the membrane has parked the effect for a
  human and handed back a handle. A real harness can't approve its own request —
  it can only wait and re-check with `(await handle)`. So `pursue/3` polls the
  handle up to `:patience` times. Between polls it invokes the
  `:while_pending` hook with the handle; that hook is supplied by the **trusted
  host** (it's the one place approve/deny lives) and is how a test, a human UI,
  or a monitor agent injects the verdict out of band. Default: a no-op, so an
  unattended harness simply reports the effect still pending.

  Returns a terminal `outcome` (`:done` / `:denied` / `:"rate-limited"` /
  `:fault`), or `{:queued, %{handle: h}}` if patience ran out with no verdict.
  """
  @spec pursue(GenServer.server(), String.t(), keyword()) :: outcome
  def pursue(server, program, opts \\ []) do
    case observe(server, program) do
      {:queued, %{handle: handle}} -> settle(server, handle, opts)
      terminal -> terminal
    end
  end

  defp settle(server, handle, opts) do
    patience = Keyword.get(opts, :patience, 5)
    while_pending = Keyword.get(opts, :while_pending, fn _ -> :ok end)

    Enum.reduce_while(1..patience, {:queued, %{handle: handle}}, fn _, _last ->
      case observe(server, ~s|(await "#{handle}")|) do
        {:queued, _} ->
          while_pending.(handle)
          {:cont, {:queued, %{handle: handle}}}

        terminal ->
          {:halt, terminal}
      end
    end)
  end

  @doc """
  Run a whole goal as a sequence of `{label, program}` steps, reacting to each
  and accumulating a trace. This is the shape a host loop takes when a plan has
  several emissions: each step is `pursue`d, its outcome recorded, and the run
  keeps going (a denial or fault on one step is data, not a crash). Returns
  `{trace, summary}` where `trace` is `[{label, outcome}]` and `summary` counts
  outcomes by tag.
  """
  @spec run(GenServer.server(), [{term(), String.t()}], keyword()) ::
          {[{term(), outcome}], %{atom() => non_neg_integer()}}
  def run(server, steps, opts \\ []) do
    trace =
      Enum.map(steps, fn {label, program} ->
        {label, pursue(server, program, opts)}
      end)

    summary =
      trace
      |> Enum.map(fn {_label, outcome} -> elem(outcome, 0) end)
      |> Enum.frequencies()

    {trace, summary}
  end
end
