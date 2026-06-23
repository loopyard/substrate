defmodule Substrate.Predicates do
  @moduledoc """
  Trusted policy predicates, named by bare symbols in a capability's `policy`
  (e.g. `(deny-if escapes-jail)`, `(deny-if host-denied)`). They run in the
  membrane (L2-trusted), against the call args and the L0 vault `ctx` — never
  visible to the agent. `describe` abstracts them away (honest-but-abstract,
  DESIGN fork 3): the agent learns *that* a call may be denied, never the rule.

  Each predicate is `(ctx, args) -> boolean`. Whatever config the rule needs —
  the jail root, a write allowlist, a host allowlist — it reads from the vault,
  so the same predicate name works across substrates without the agent ever
  seeing the list it's checked against.

  ## Default-deny

  The allowlist predicates (`write-denied`, `host-denied`) are the deny-all
  posture: they refuse anything not explicitly listed, and an *unbound* allowlist
  refuses everything. Opening a hole is an L0 act — adding an entry to the vault
  at mount — never something the agent can do from inside.
  """

  alias Substrate.Vault

  @safe_subdir "notes"

  # --- jail containment (used by every fs-backed substrate) ---

  @doc "True when the resolved path leaves the jail root entirely."
  def escapes_jail?(ctx, %{path: rel}) do
    root = Vault.fetch!(ctx, :fs_root)
    abs = Path.expand(Path.join(root, rel))
    not contained?(abs, root)
  end

  def escapes_jail?(_ctx, _args), do: false

  @doc "True when a write/delete targets anything outside the safe subdir."
  def outside_safe?(ctx, %{path: rel}) do
    root = Vault.fetch!(ctx, :fs_root)
    abs = Path.expand(Path.join(root, rel))
    not contained?(abs, Path.join(root, @safe_subdir))
  end

  def outside_safe?(_ctx, _args), do: false

  @doc "True when the resolved path is inside a given top-level zone dir."
  def in_zone?(ctx, %{path: rel}, zone) do
    root = Vault.fetch!(ctx, :fs_root)
    abs = Path.expand(Path.join(root, rel))
    contained?(abs, Path.join(root, zone))
  end

  def in_zone?(_ctx, _args, _zone), do: false

  # --- default-deny allowlists ---

  @doc """
  True when a write target is NOT inside any allowlisted dir (`:fs_allow`, a list
  of dirs relative to the jail root). Deny-all by default: no allowlist → every
  write denied.
  """
  def write_denied?(ctx, %{path: rel}) do
    root = Vault.fetch!(ctx, :fs_root)
    allow = Vault.fetch(ctx, :fs_allow, [])
    abs = Path.expand(Path.join(root, rel))
    not Enum.any?(allow, fn dir -> contained?(abs, Path.expand(Path.join(root, dir))) end)
  end

  def write_denied?(_ctx, _args), do: true

  @doc """
  True when an ABSOLUTE path is NOT inside any allowlisted root (`:fs_roots`, a
  list of absolute dirs). Default-deny: no list → everything denied. This is the
  "/home yes, /root no" rule — the agent names a real absolute path and the
  membrane refuses anything that isn't under an allowed root, even though the
  process itself (running as root) could touch it.
  """
  def outside_roots?(ctx, %{path: path}) when is_binary(path) do
    abs = Path.expand(path)
    roots = Vault.fetch(ctx, :fs_roots, [])
    not Enum.any?(roots, fn r -> contained?(abs, Path.expand(r)) end)
  end

  def outside_roots?(_ctx, _args), do: true

  @doc """
  True when a URL's host is NOT on the allowlist (`:http_allow`, a list of exact
  hostnames). Deny-all by default: no allowlist, an unparseable URL, or a missing
  host → denied.
  """
  def host_denied?(ctx, %{url: url}) when is_binary(url) do
    allow = Vault.fetch(ctx, :http_allow, [])

    case URI.parse(url).host do
      nil -> true
      host -> host not in allow
    end
  end

  def host_denied?(_ctx, _args), do: true

  # --- shared geometry ---

  defp contained?(abs, dir), do: abs == dir or String.starts_with?(abs, dir <> "/")

  # --- name -> predicate (compiled into each policy rule at mount) ---

  def lookup("escapes-jail"), do: &escapes_jail?/2
  def lookup("outside-safe"), do: &outside_safe?/2
  def lookup("write-denied"), do: &write_denied?/2
  def lookup("outside-roots"), do: &outside_roots?/2
  def lookup("host-denied"), do: &host_denied?/2
  def lookup("in-bulk"), do: &in_zone?(&1, &2, "bulk")
  def lookup("in-data"), do: &in_zone?(&1, &2, "data")
  def lookup("in-published"), do: &in_zone?(&1, &2, "published")
  def lookup("in-archive"), do: &in_zone?(&1, &2, "archive")
  def lookup(other), do: raise("unknown policy predicate: #{other}")
end
