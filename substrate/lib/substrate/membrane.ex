defmodule Substrate.Membrane do
  @moduledoc """
  The membrane — intent becomes (or doesn't become) effect. A capability call
  does not return a value; it returns a **disposition** (DESIGN: the errno of
  the syscall ABI): `:done` · `:queued` · `:rate-limited` · `:denied`.

  Adjudication is a tiered pipeline, cheap-and-static first (DESIGN fork 8):

      revoked?  ->  validate  ->  deny-if  ->  rate  ->  confirm-if  ->  execute

  Only the last step crosses into L1. Everything before it is the trusted
  disposer ruling on the untrusted proposer's intent. The signature is frozen
  the whole way through — a revoked capability still *exists*, it just returns
  `:denied` (ABI stable, errno dynamic).

  `adjudicate/3` is pure over the server state: it takes `{state, name, args}`
  and returns `{result, state}`, where result is a disposition tuple
  `{:disposition, tag, payload}` or `{:invalid, message}` for a malformed call
  (which the L2 evaluator raises as a fault — killing hallucinated calls).
  """

  def adjudicate(state, name, args) do
    cap = Map.fetch!(state.caps, name)

    cond do
      MapSet.member?(state.revoked, name) ->
        {disp(:denied, %{reason: "capability suspended"}), state}

      msg = missing_params(cap, args) ->
        {{:invalid, msg}, state}

      reason = denied_by_policy(cap, state.ctx, args) ->
        {disp(:denied, %{reason: reason}), state}

      true ->
        case check_rate(cap, state, state.ctx, args) do
          {:limited, retry} ->
            {disp(:"rate-limited", %{retry_after: retry}), state}

          {:ok, state} ->
            proceed(cap, state, name, args)
        end
    end
  end

  defp proceed(cap, state, name, args) do
    if confirm_required?(cap, state.ctx, args) do
      enqueue(state, name, args)
    else
      {execute(cap, state.ctx, args), state}
    end
  end

  # --- pipeline steps ---

  defp missing_params(cap, args) do
    missing = Enum.reject(cap.params, fn p -> Map.has_key?(args, p.name) end)

    case missing do
      [] -> nil
      ps -> "missing required param(s): " <> Enum.map_join(ps, ", ", &inspect(&1.name))
    end
  end

  defp denied_by_policy(cap, ctx, args) do
    Enum.find_value(cap.policy, fn
      {:deny_if, _name, pred} -> if pred.(ctx, args), do: "denied by policy"
      _ -> nil
    end)
  end

  defp check_rate(cap, state, ctx, args) do
    case Enum.find(cap.policy, &match?({:rate, _, _, _}, &1)) do
      nil ->
        {:ok, state}

      {:rate, _l, _w, {_name, gfun}} = rule ->
        # location-guarded rate: only applies where the guard holds (else unlimited)
        if gfun.(ctx, args), do: apply_rate(rule, cap, state), else: {:ok, state}

      rule ->
        apply_rate(rule, cap, state)
    end
  end

  defp apply_rate({:rate, limit, window, _guard}, cap, state) do
        now = System.os_time(:second)
        {count, start} = Map.get(state.rate, cap.name, {0, now})
        {count, start} = if now - start >= window, do: {0, now}, else: {count, start}

        if count >= limit do
          {:limited, window - (now - start)}
        else
          {:ok, %{state | rate: Map.put(state.rate, cap.name, {count + 1, start})}}
        end
  end

  defp confirm_required?(cap, ctx, args) do
    Enum.any?(cap.policy, fn
      {:confirm_if, _name, pred} -> pred.(ctx, args)
      _ -> false
    end)
  end

  defp enqueue(state, name, args) do
    handle = "eff_#{state.eff_counter + 1}"
    effect = %{name: name, args: args, status: :pending}
    state = %{state | eff_counter: state.eff_counter + 1, queue: Map.put(state.queue, handle, effect)}
    {disp(:queued, %{handle: handle, reason: "pending human review"}), state}
  end

  # the only step that crosses into L1
  defp execute(cap, ctx, args) do
    {mod, fun} = cap.bind

    # Resolve the capability's auth template against the vault and hand the
    # binding a ctx carrying the concrete headers. The secret is read here, in
    # trusted code, microseconds before the socket — never a value in L2.
    ctx = Substrate.Vault.put(ctx, :__auth_headers__, Substrate.Auth.resolve(cap.auth, ctx))

    case apply(mod, fun, [ctx, args]) do
      {:ok, payload} -> disp(:done, payload)
      {:error, reason} -> disp(:denied, %{reason: to_string(reason)})
    end
  rescue
    # a native driver (or a misconfigured secret) must not be able to crash the
    # membrane — it degrades to a denial the agent reads like any other.
    e -> disp(:denied, %{reason: "binding error: " <> Exception.message(e)})
  end

  # --- effect resolution (the human/monitor ruling on a queued effect) ---

  def resolve(state, handle, :approve) do
    case Map.get(state.queue, handle) do
      %{status: :pending} = eff ->
        cap = Map.fetch!(state.caps, eff.name)
        result = execute(cap, state.ctx, eff.args)
        store_result(state, handle, eff, result)

      _ ->
        {disp(:denied, %{reason: "no such pending effect"}), state}
    end
  end

  def resolve(state, handle, :deny) do
    case Map.get(state.queue, handle) do
      %{status: :pending} = eff ->
        result = disp(:denied, %{reason: "rejected by human"})
        store_result(state, handle, eff, result)

      _ ->
        {disp(:denied, %{reason: "no such pending effect"}), state}
    end
  end

  defp store_result(state, handle, eff, {:disposition, tag, payload} = result) do
    updated = Map.put(state.queue, handle, %{eff | status: {tag, payload}})
    {result, %{state | queue: updated}}
  end

  def await(state, handle) do
    case Map.get(state.queue, handle) do
      %{status: :pending} -> disp(:queued, %{handle: handle, reason: "still pending"})
      %{status: {tag, payload}} -> disp(tag, payload)
      nil -> disp(:denied, %{reason: "unknown effect handle"})
    end
  end

  defp disp(tag, payload), do: {:disposition, tag, payload}
end
