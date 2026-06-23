defmodule Substrate.Lisp.Stdlib.Maps do
  @moduledoc """
  Stdlib group: maps. Keys are whatever the program supplies — string keys from
  `parse-json`, keyword atoms from literals; `assoc` returns a new map (pure).
  """
  def names, do: ~w(get assoc keys vals)

  def call("get", [m, k], _ap) when is_map(m), do: Map.get(m, k)
  def call("assoc", [m, k, v], _ap) when is_map(m), do: Map.put(m, k, v)
  def call("keys", [m], _ap) when is_map(m), do: Map.keys(m)
  def call("vals", [m], _ap) when is_map(m), do: Map.values(m)
end
