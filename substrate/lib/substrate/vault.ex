defmodule Substrate.Vault do
  @moduledoc """
  L0 — the credential store. The genuinely dangerous thing for a filesystem
  substrate is **the jail root path**: whoever holds it can address the real
  disk. So it lives here, in trusted code, named exactly once at mount.

  The agent never receives a `ctx`. There is no expressible operation at L2 that
  returns one — the credential is simply not in the sandbox's value-space
  (DESIGN: the input clamp / capability wall). The native edge (L1) is the only
  caller of `fetch!/2`.
  """

  @opaque t :: %__MODULE__{secrets: map()}
  defstruct secrets: %{}

  @doc "Mint a ctx from a credential map. Called at L0 mount time only."
  def mint(secrets) when is_map(secrets), do: %__MODULE__{secrets: secrets}

  @doc "Fetch a secret on the native side. Raises if the binding is absent."
  def fetch!(%__MODULE__{secrets: s}, key) do
    case Map.fetch(s, key) do
      {:ok, v} -> v
      :error -> raise "vault: no credential bound for #{inspect(key)}"
    end
  end
end
