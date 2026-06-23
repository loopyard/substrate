defmodule Substrate.Lisp.Stdlib.Maps do
  @moduledoc """
  Stdlib group: maps. Keys are whatever the program supplies — string keys from
  `parse-json`, keyword atoms from literals; `associate` returns a new map (pure).
  """
  def namespace, do: "map"
  def names, do: ~w(get associate keys values)

  def call("get", [m, k], _ap) when is_map(m), do: Map.get(m, k)
  def call("associate", [m, k, v], _ap) when is_map(m), do: Map.put(m, k, v)
  def call("keys", [m], _ap) when is_map(m), do: Map.keys(m)
  def call("values", [m], _ap) when is_map(m), do: Map.values(m)
end
