defmodule Substrate.FS do
  @moduledoc """
  L1 — the native filesystem client. Full authority: it actually touches the
  disk. It runs *inside* the trust boundary and is never nameable from L2 (the
  manifest's `bind` is stripped at the wall).

  Every function takes the L0-minted `ctx` and the call args. The jail root is
  read from the vault here — the one place it is named on the hot path. Paths
  are resolved against the root and re-checked for escape: defense in depth
  behind the membrane's `deny-if escapes-jail`. This is the input clamp made
  literal — the agent passes a *relative* path and can never name anything
  outside the root, because the root is not a value it holds.

  Returns `{:ok, payload_map}` or `{:error, reason_atom}`. The membrane maps
  that onto a disposition; a domain failure (missing file) still rode through a
  permitted effect, so it returns under `:done` with an `:error` key.
  """

  alias Substrate.Vault

  def list(ctx, %{path: rel}) do
    with {:ok, abs} <- resolve(ctx, rel),
         {:ok, names} <- File.ls(abs) do
      {:ok, %{entries: Enum.sort(names)}}
    end
  end

  def read(ctx, %{path: rel}) do
    with {:ok, abs} <- resolve(ctx, rel) do
      case File.read(abs) do
        {:ok, content} -> {:ok, %{content: content, bytes: byte_size(content)}}
        {:error, reason} -> {:ok, %{error: to_string(reason)}}
      end
    end
  end

  def write(ctx, %{path: rel, content: content}) do
    with {:ok, abs} <- resolve(ctx, rel) do
      File.mkdir_p!(Path.dirname(abs))

      case File.write(abs, content) do
        :ok -> {:ok, %{bytes: byte_size(content), path: rel}}
        {:error, reason} -> {:ok, %{error: to_string(reason)}}
      end
    end
  end

  def delete(ctx, %{path: rel}) do
    with {:ok, abs} <- resolve(ctx, rel) do
      case File.rm(abs) do
        :ok -> {:ok, %{deleted: rel}}
        {:error, reason} -> {:ok, %{error: to_string(reason)}}
      end
    end
  end

  # The credential — the jail root — is named here and nowhere the agent can see.
  defp resolve(ctx, rel) do
    root = Vault.fetch!(ctx, :fs_root)
    abs = Path.expand(Path.join(root, rel))

    if abs == root or String.starts_with?(abs, root <> "/") do
      {:ok, abs}
    else
      {:error, :escapes_jail}
    end
  end
end
