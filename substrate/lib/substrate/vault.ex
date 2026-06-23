defmodule Substrate.Vault do
  @moduledoc """
  L0 — the credential store. The genuinely dangerous things live here, in
  trusted code, named exactly once at mount: the filesystem **jail root**, and
  the **allowlists** that decide which dirs may be written and which hosts may be
  reached. None of these is a value in the agent's world — there is no
  expressible L2 operation that returns a `ctx` (DESIGN: the input clamp /
  capability wall). The native edge (L1) and the trusted predicates (L2) are the
  only callers.

  An allowlist in the vault is the deny-all posture made structural: a predicate
  that consults `:http_allow` refuses every host that isn't in it, and the agent
  can neither read nor name the list to learn what's on it.
  """

  @opaque t :: %__MODULE__{secrets: map()}
  defstruct secrets: %{}

  @doc "Mint a ctx from a credential map. Called at L0 mount time only."
  def mint(secrets) when is_map(secrets), do: %__MODULE__{secrets: secrets}

  @doc "Fetch a required secret on the native side. Raises if the binding is absent."
  def fetch!(%__MODULE__{secrets: s}, key) do
    case Map.fetch(s, key) do
      {:ok, v} -> v
      :error -> raise "vault: no credential bound for #{inspect(key)}"
    end
  end

  @doc """
  Fetch an optional config value, falling back to `default`. Used by the
  allowlist predicates: an unbound allowlist means *nothing* is allowed (the
  default-deny posture), so the default is the empty list, not a crash.
  """
  def fetch(%__MODULE__{secrets: s}, key, default \\ nil), do: Map.get(s, key, default)
end
