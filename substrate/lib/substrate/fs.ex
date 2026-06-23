defmodule Substrate.FS do
  @moduledoc """
  L1 — the native filesystem client. Full authority: it actually touches the
  disk. It runs *inside* the trust boundary and is never nameable from L2 (the
  substrate's `bind` is stripped at the wall).

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

  # --- absolute-path mode: allowlist of roots (the "/home yes, /root no" model) ---
  #
  # Here the agent names a REAL absolute path. There is no jail root to hide; the
  # confinement is an allowlist of roots (`:fs_roots`) that the membrane checks
  # before us and we re-check here in trusted code. The process may run as root —
  # the OS would let it write anywhere — so this clamp is the only thing standing
  # between the agent and the rest of the disk.

  def read_at(ctx, %{path: path}) do
    with {:ok, abs} <- within_roots(ctx, path) do
      case File.read(abs) do
        {:ok, content} -> {:ok, %{content: content, bytes: byte_size(content)}}
        {:error, reason} -> {:ok, %{error: to_string(reason)}}
      end
    end
  end

  def write_at(ctx, %{path: path, content: content}) do
    with {:ok, abs} <- within_roots(ctx, path) do
      File.mkdir_p!(Path.dirname(abs))

      case File.write(abs, content) do
        :ok -> {:ok, %{bytes: byte_size(content), path: abs}}
        {:error, reason} -> {:ok, %{error: to_string(reason)}}
      end
    end
  end

  defp within_roots(ctx, path) do
    abs = Path.expand(path)
    roots = Vault.fetch(ctx, :fs_roots, [])

    if Enum.any?(roots, fn r -> contained?(abs, Path.expand(r)) end) do
      {:ok, abs}
    else
      {:error, :outside_allowed_roots}
    end
  end

  defp contained?(abs, dir), do: abs == dir or String.starts_with?(abs, dir <> "/")

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
