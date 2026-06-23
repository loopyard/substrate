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
  # creds: the accumulated L0 credential map the vault ctx is minted from;
  # reveal: per-namespace `reveal_rules` flag for `describe`; audit/seq: the
  # trusted-side observability log of every adjudicated call.
  defstruct subs: [], caps: %{}, creds: %{}, ctx: nil,
            revoked: MapSet.new(), rate: %{}, queue: %{}, eff_counter: 0,
            reveal: %{}, audit: [], seq: 0

  @audit_cap 1000

  # --- lifecycle ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @impl true
  # a child surface minted by `attenuate/2` arrives with its state pre-built
  def init({:child, %__MODULE__{} = state}), do: {:ok, state}
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

  @doc """
  Mint an **attenuated** child surface from this one — the trusted core of the
  L2 `grant`. `narrowing` may carry `:caps` (a subset of held capability names),
  `:fs_allow` / `:http_allow` (subsets of the granted allowlists), and `:rate`
  (a ceiling). It can only ever *narrow*: a request to grant a capability not
  held, a dir not within the granted ones, or a host not on the list comes back
  `{:denied, reason}` — never a wider surface. On success returns `{:ok, child}`,
  an independent server (own membrane state) the caller can run sub-programs
  against. The child inherits secrets but reaches strictly less of the world.
  """
  def attenuate(server, narrowing), do: GenServer.call(server, {:attenuate, narrowing})

  @doc "The trusted-side audit log: every adjudicated call, oldest first."
  def audit(server), do: GenServer.call(server, {:audit})

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
    {ns, ns_doc, caps, config} = Capability.compile_manifest(ast)

    # creds layer: prior mounts < this manifest's own resources/secrets <
    # explicit mount credentials (the integrator always gets the last word).
    creds =
      state.creds
      |> Map.merge(resolve_config(config))
      |> Map.merge(Keyword.get(opts, :credentials, %{}))

    sub = %{ns: ns, doc: ns_doc, order: Enum.map(caps, & &1.name)}

    state = %{
      state
      | subs: state.subs ++ [sub],
        caps: Map.merge(state.caps, Map.new(caps, &{&1.name, &1})),
        creds: creds,
        ctx: Vault.mint(creds),
        reveal: Map.put(state.reveal, ns, Keyword.get(opts, :reveal_rules, false))
    }

    {:reply, :ok, state}
  end

  def handle_call({:call, name, args}, _from, state) do
    if Map.has_key?(state.caps, name) do
      {result, state} = Membrane.adjudicate(state, name, args)
      {:reply, result, log_call(state, name, result)}
    else
      # never existed — genuinely unbound. (Revoked is different: still present.)
      {:reply, {:unbound, name}, log_call(state, name, {:unbound, name})}
    end
  end

  def handle_call({:attenuate, narrowing}, _from, state) do
    case build_child(state, narrowing) do
      {:ok, child_state} ->
        {:ok, child} = GenServer.start_link(__MODULE__, {:child, child_state}, [])
        {:reply, {:ok, child}, log_call(state, "grant", {:disposition, :granted, %{}})}

      {:denied, _reason} = denial ->
        # a denied grant — especially a widening attempt — is a security event
        {:reply, denial, log_call(state, "grant", {:disposition, :denied, %{reason: elem(denial, 1)}})}
    end
  end

  def handle_call({:audit}, _from, state),
    do: {:reply, Enum.reverse(state.audit), state}

  def handle_call({:known?, name}, _from, state),
    do: {:reply, Map.has_key?(state.caps, name), state}

  def handle_call({:revoke, name}, _from, state),
    do: {:reply, :ok, %{state | revoked: MapSet.put(state.revoked, name)}}

  def handle_call({:restore, name}, _from, state),
    do: {:reply, :ok, %{state | revoked: MapSet.delete(state.revoked, name)}}

  def handle_call({:resolve, handle, decision}, _from, state) do
    {result, state} = Membrane.resolve(state, handle, decision)
    {:reply, result, log_call(state, "resolve:#{decision}", result)}
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
      Map.has_key?(state.caps, target) ->
        Capability.describe(state.caps[target], reveal: reveal_for?(state, target))
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

  # a capability inherits its namespace's reveal_rules flag
  defp reveal_for?(state, cap_name) do
    ns = cap_name |> String.split("/") |> hd()
    Map.get(state.reveal, ns, false)
  end

  # --- manifest config → vault credentials (resources + resolved secrets) ---

  defp resolve_config(%{resources: resources, secrets: secrets}) do
    resolved =
      secrets
      |> Enum.map(fn {key, source} -> {key, resolve_source(source)} end)
      |> Enum.reject(fn {_key, val} -> is_nil(val) end)
      |> Map.new()

    Map.merge(resources, resolved)
  end

  defp resolve_source({:lit, val}), do: val
  defp resolve_source({:env, var}), do: System.get_env(var)

  # --- audit log ---

  defp log_call(state, name, result) do
    entry = %{seq: state.seq + 1, at: now(), cap: name, outcome: outcome_of(result)}
    %{state | seq: state.seq + 1, audit: Enum.take([entry | state.audit], @audit_cap)}
  end

  defp now do
    System.os_time(:second)
  rescue
    _ -> 0
  end

  defp outcome_of({:disposition, tag, payload}), do: {tag, Map.get(payload, :reason)}
  defp outcome_of({:invalid, msg}), do: {:invalid, msg}
  defp outcome_of({:unbound, _}), do: {:unbound, nil}
  defp outcome_of(other), do: {:other, inspect(other)}

  # --- attenuation: build a strictly-narrower child surface (the `grant` core) ---

  defp build_child(state, narrowing) do
    with {:ok, caps} <- narrow_caps(state, narrowing),
         {:ok, creds} <- narrow_creds(state, narrowing) do
      caps = apply_rate_narrowing(caps, narrowing)

      child = %__MODULE__{
        subs: rebuild_subs(state, caps),
        caps: caps,
        creds: creds,
        ctx: Vault.mint(creds),
        reveal: state.reveal
      }

      {:ok, child}
    end
  end

  # caps: requested names must all be held by the parent (never grant what you lack)
  defp narrow_caps(state, %{caps: names}) when is_list(names) do
    case Enum.find(names, &(not Map.has_key?(state.caps, &1))) do
      nil -> {:ok, Map.take(state.caps, names)}
      missing -> {:denied, "cannot grant capability not held: #{missing}"}
    end
  end
  defp narrow_caps(state, _narrowing), do: {:ok, state.caps}

  # allowlists: every requested dir/host must sit within what the parent holds
  defp narrow_creds(state, narrowing) do
    parent_fs = Map.get(state.creds, :fs_allow, [])
    parent_http = Map.get(state.creds, :http_allow, [])

    with :ok <- check_fs(Map.get(narrowing, :fs_allow), parent_fs),
         :ok <- check_http(Map.get(narrowing, :http_allow), parent_http) do
      creds =
        state.creds
        |> maybe_put(:fs_allow, Map.get(narrowing, :fs_allow))
        |> maybe_put(:http_allow, Map.get(narrowing, :http_allow))

      {:ok, creds}
    end
  end

  defp maybe_put(creds, _key, nil), do: creds
  defp maybe_put(creds, key, val), do: Map.put(creds, key, val)

  defp check_fs(nil, _parent), do: :ok
  defp check_fs(req, parent) do
    case Enum.find(req, fn d -> not Enum.any?(parent, &dir_contains?(&1, d)) end) do
      nil -> :ok
      bad -> {:denied, "cannot widen fs_allow: #{bad} is outside the granted directories"}
    end
  end

  defp dir_contains?(parent, child), do: child == parent or String.starts_with?(child, parent <> "/")

  defp check_http(nil, _parent), do: :ok
  defp check_http(req, parent) do
    case Enum.find(req, fn h -> h not in parent end) do
      nil -> :ok
      bad -> {:denied, "cannot widen http_allow: #{bad} is not a granted host"}
    end
  end

  # rate: a ceiling applied to every granted cap; only ever tightens, never loosens
  defp apply_rate_narrowing(caps, %{rate: nil}), do: caps
  defp apply_rate_narrowing(caps, %{rate: spec}) when is_binary(spec) do
    {n, w} = parse_rate(spec)
    Map.new(caps, fn {name, cap} -> {name, tighten_rate(cap, n, w)} end)
  end
  defp apply_rate_narrowing(caps, _narrowing), do: caps

  defp tighten_rate(cap, n, w) do
    new_rule = {:rate, n, w, nil}

    policy =
      case Enum.find(cap.policy, &match?({:rate, _, _, _}, &1)) do
        nil ->
          cap.policy ++ [new_rule]

        {:rate, pn, pw, _} = existing ->
          # smaller calls-per-second is stricter; keep the parent's if it's already tighter
          if n / w <= pn / pw,
            do: Enum.map(cap.policy, fn r -> if(r == existing, do: new_rule, else: r) end),
            else: cap.policy
      end

    %{cap | policy: policy}
  end

  defp parse_rate(spec) do
    [n, unit] = String.split(spec, "/")
    {String.to_integer(n), window_seconds(unit)}
  end

  defp window_seconds("sec"), do: 1
  defp window_seconds("min"), do: 60
  defp window_seconds("hour"), do: 3600
  defp window_seconds("day"), do: 86_400

  # the child's namespace listings, pruned to the capabilities it actually holds
  defp rebuild_subs(state, caps) do
    state.subs
    |> Enum.map(fn sub -> %{sub | order: Enum.filter(sub.order, &Map.has_key?(caps, &1))} end)
    |> Enum.reject(fn sub -> sub.order == [] end)
  end
end
