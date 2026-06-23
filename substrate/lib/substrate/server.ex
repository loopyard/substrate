defmodule Substrate.Server do
  @moduledoc """
  One running substrate instance. Holds the **live registry** — capabilities are
  *data in a table*, not compiled into the agent — plus the membrane's mutable
  state (rate counters, the approval queue) and the L0 vault `ctx`.

  Because the surface is a table, granting/revoking a capability is a write to
  this GenServer's state, atomic with respect to the call stack. The surface can
  change *while the agent runs* (DESIGN: live & mutable). `revoke/2` keeps the
  signature and flips the capability to `:denied` — it never vanishes.

  Several substrates can share one surface: each `mount/3` appends a namespace
  (e.g. `fs`, then `http`) and *merges* its L0 credentials into the vault, so an
  agent can compose across them — `http/get` a file, then `fs/write` it — while
  every call still funnels through the same membrane. The GenServer serializes
  calls, which is what lets the membrane keep consistent rate/queue state.
  """
  use GenServer

  alias Substrate.{Capability, Membrane, Vault}

  # subs: per-namespace listings; caps: flat name -> %Capability{} registry;
  # creds: the accumulated L0 credential map the vault ctx is minted from.
  defstruct subs: [], caps: %{}, creds: %{}, ctx: nil,
            revoked: MapSet.new(), rate: %{}, queue: %{}, eff_counter: 0

  # --- lifecycle ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{ctx: Vault.mint(%{})}}

  # --- L0/L2 authoring API (trusted side of the wall) ---

  @doc """
  Mount a manifest, binding its credentials at L0. The only place the jail root
  and allowlists are named. Mounting again *adds* a namespace and merges
  credentials — it does not replace the prior surface.
  """
  def mount(server, manifest_ast, opts) do
    GenServer.call(server, {:mount, manifest_ast, opts})
  end

  def revoke(server, name), do: GenServer.call(server, {:revoke, name})
  def restore(server, name), do: GenServer.call(server, {:restore, name})

  # the "human" (or a monitor agent) ruling on a queued effect
  def approve(server, handle), do: GenServer.call(server, {:resolve, handle, :approve})
  def deny(server, handle), do: GenServer.call(server, {:resolve, handle, :deny})

  # --- L3 harness API (untrusted side — only intent + introspection) ---

  def call(server, name, args), do: GenServer.call(server, {:call, name, args})
  def await(server, handle), do: GenServer.call(server, {:await, handle})
  def describe(server, target \\ nil), do: GenServer.call(server, {:describe, target})
  def known?(server, name), do: GenServer.call(server, {:known?, name})

  # --- handlers ---

  @impl true
  def handle_call({:mount, ast, opts}, _from, state) do
    {ns, ns_doc, caps} = Capability.compile_manifest(ast)
    creds = Map.merge(state.creds, Keyword.get(opts, :credentials, %{}))
    sub = %{ns: ns, doc: ns_doc, order: Enum.map(caps, & &1.name)}

    state = %{
      state
      | subs: state.subs ++ [sub],
        caps: Map.merge(state.caps, Map.new(caps, &{&1.name, &1})),
        creds: creds,
        ctx: Vault.mint(creds)
    }

    {:reply, :ok, state}
  end

  def handle_call({:call, name, args}, _from, state) do
    if Map.has_key?(state.caps, name) do
      {result, state} = Membrane.adjudicate(state, name, args)
      {:reply, result, state}
    else
      # never existed — genuinely unbound. (Revoked is different: still present.)
      {:reply, {:unbound, name}, state}
    end
  end

  def handle_call({:known?, name}, _from, state),
    do: {:reply, Map.has_key?(state.caps, name), state}

  def handle_call({:revoke, name}, _from, state),
    do: {:reply, :ok, %{state | revoked: MapSet.put(state.revoked, name)}}

  def handle_call({:restore, name}, _from, state),
    do: {:reply, :ok, %{state | revoked: MapSet.delete(state.revoked, name)}}

  def handle_call({:resolve, handle, decision}, _from, state) do
    {result, state} = Membrane.resolve(state, handle, decision)
    {:reply, result, state}
  end

  def handle_call({:await, handle}, _from, state),
    do: {:reply, Membrane.await(state, handle), state}

  def handle_call({:describe, target}, _from, state),
    do: {:reply, render_describe(state, target), state}

  # --- describe rendering: the self-describing surface ---

  # no target: list every mounted substrate
  defp render_describe(state, nil),
    do: Enum.map_join(state.subs, "\n\n", &render_namespace(&1, state))

  defp render_describe(state, target) do
    cond do
      sub = Enum.find(state.subs, &(&1.ns == target)) -> render_namespace(sub, state)
      Map.has_key?(state.caps, target) -> Capability.describe(state.caps[target])
      true -> "; unknown: #{target}"
    end
  end

  defp render_namespace(sub, state) do
    header = "#{sub.ns} — #{inspect(sub.doc)}"

    rows =
      Enum.map_join(sub.order, "\n", fn name ->
        cap = state.caps[name]
        tag = if MapSet.member?(state.revoked, name), do: "   [revoked]", else: ""
        "  " <> Capability.signature(cap) <> tag
      end)

    header <> "\n" <> rows
  end
end
