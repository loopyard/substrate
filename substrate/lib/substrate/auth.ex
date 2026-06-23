defmodule Substrate.Auth do
  @moduledoc """
  Resolves a capability's `(auth ...)` declaration into concrete request headers,
  trusted-side, against the L0 vault. This is the seam that lets a substrate say
  *"this resource is authenticated"* declaratively while the secret itself stays
  in the vault: the substrate names a `(secret :key …)`, the `auth` form weaves it
  into a header template, and the membrane resolves the template the instant
  before it crosses into L1 — injecting the result into a per-call ctx the native
  binding reads back. The agent emits `(http/get :url …)` and the call goes out
  authenticated; the token is never a value in L2, never rendered by `describe`.

  ## The tiny template language (trusted-tier, never agent-facing)

      (auth (header "Authorization" (string "Bearer " (secret :gh-token)))
            (header "Accept"        "application/vnd.github+json"))

  A value expression is a string literal, a `(secret :key)` lookup, or a
  `(string part…)` concatenation of those. That is deliberately the whole grammar —
  enough to build a bearer/basic header, too little to be a general computer.
  """

  alias Substrate.Vault

  @doc """
  Compile an `(auth …)` clause's AST into a header spec: a list of
  `{name, value_template}` where each template is a list of `{:lit, s}` /
  `{:secret, key}` parts. Stored on the `%Capability{}` at mount; resolved per
  call. Returns `nil` for a capability with no auth.
  """
  def compile({:list, [{:sym, "auth"} | headers]}), do: Enum.map(headers, &compile_header/1)
  def compile(nil), do: nil

  defp compile_header({:list, [{:sym, "header"}, {:str, name}, value_expr]}),
    do: {name, compile_value(value_expr)}

  defp compile_value({:str, s}), do: [{:lit, s}]
  defp compile_value({:list, [{:sym, "secret"}, {:kw, key}]}), do: [{:secret, key}]
  defp compile_value({:list, [{:sym, "string"} | parts]}), do: Enum.flat_map(parts, &compile_value/1)

  @doc """
  Resolve a compiled header spec against the vault into concrete
  `[{name, value}]`. Each `{:secret, key}` is read from the vault; a missing
  secret raises (trusted-side config error — fails loud at the operator, never
  reaches the agent). Returns `[]` for `nil`.
  """
  def resolve(nil, _ctx), do: []

  def resolve(spec, ctx) do
    Enum.map(spec, fn {name, template} -> {name, render(template, ctx)} end)
  end

  defp render(template, ctx) do
    Enum.map_join(template, "", fn
      {:lit, s} -> s
      {:secret, key} -> to_string(Vault.fetch!(ctx, key))
    end)
  end
end
