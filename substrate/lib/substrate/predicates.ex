defmodule Substrate.Predicates do
  @moduledoc """
  Trusted policy predicates, named by bare symbols in a capability's `policy`
  (e.g. `(deny-if escapes-jail)`, `(confirm-if outside-safe)`). They run in the
  membrane (L2-trusted), against the call args and the jail root — never visible
  to the agent. `describe` abstracts them away (honest-but-abstract, DESIGN fork
  3): the agent learns *that* a call may be denied or queued, never the rule.

  Each predicate is `(root, args) -> boolean`.
  """

  @safe_subdir "notes"

  @doc "True when the resolved path leaves the jail root entirely."
  def escapes_jail?(root, %{path: rel}) do
    abs = Path.expand(Path.join(root, rel))
    not (abs == root or String.starts_with?(abs, root <> "/"))
  end

  def escapes_jail?(_root, _args), do: false

  @doc "True when a write/delete targets anything outside the safe subdir."
  def outside_safe?(root, %{path: rel}) do
    abs = Path.expand(Path.join(root, rel))
    safe = Path.join(root, @safe_subdir)
    not (abs == safe or String.starts_with?(abs, safe <> "/"))
  end

  def outside_safe?(_root, _args), do: false

  @doc "True when the resolved path is inside a given top-level zone dir."
  def in_zone?(root, %{path: rel}, zone) do
    abs = Path.expand(Path.join(root, rel))
    dir = Path.join(root, zone)
    abs == dir or String.starts_with?(abs, dir <> "/")
  end

  def in_zone?(_root, _args, _zone), do: false

  def lookup("escapes-jail"), do: &escapes_jail?/2
  def lookup("outside-safe"), do: &outside_safe?/2
  def lookup("in-bulk"), do: &in_zone?(&1, &2, "bulk")
  def lookup("in-data"), do: &in_zone?(&1, &2, "data")
  def lookup("in-published"), do: &in_zone?(&1, &2, "published")
  def lookup("in-archive"), do: &in_zone?(&1, &2, "archive")
  def lookup(other), do: raise("unknown policy predicate: #{other}")
end
