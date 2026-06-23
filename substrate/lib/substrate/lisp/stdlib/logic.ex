defmodule Substrate.Lisp.Stdlib.Logic do
  @moduledoc """
  Stdlib group: equality, ordering, and boolean negation. (`and`/`or` are
  special forms in the evaluator — they short-circuit — not builtins.)
  """
  alias Substrate.Lisp.Stdlib

  def names, do: ~w(= not < > <= >=)

  def call("=", [a | rest], _ap), do: Enum.all?(rest, &(&1 == a))
  def call("not", [a], _ap), do: not Stdlib.truthy?(a)
  def call("<", [a, b], _ap), do: a < b
  def call(">", [a, b], _ap), do: a > b
  def call("<=", [a, b], _ap), do: a <= b
  def call(">=", [a, b], _ap), do: a >= b
end
