defmodule Substrate.Show do
  @moduledoc "Render runtime values back into the substrate Lisp's surface syntax."

  @doc "Canonical s-expression form (strings quoted). Used to print dispositions."
  def form({:disposition, tag, payload}), do: "(:#{tag} #{form(payload)})"
  def form(v) when is_binary(v), do: inspect(v)
  def form(v) when is_integer(v), do: Integer.to_string(v)
  def form(v) when is_boolean(v), do: to_string(v)
  def form(nil), do: "nil"
  def form(v) when is_atom(v), do: ":" <> Atom.to_string(v)
  def form(v) when is_list(v), do: "[" <> Enum.map_join(v, " ", &form/1) <> "]"

  def form(v) when is_map(v) do
    "{" <> Enum.map_join(v, " ", fn {k, val} -> ":#{k} #{form(val)}" end) <> "}"
  end

  def form({:closure, _, _, _, _}), do: "#<fn>"

  @doc "Human display: raw for strings, canonical form otherwise. Used by log/string."
  def display(v) when is_binary(v), do: v
  def display(v), do: form(v)
end
