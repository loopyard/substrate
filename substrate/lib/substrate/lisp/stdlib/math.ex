defmodule Substrate.Lisp.Stdlib.Math do
  @moduledoc "Stdlib group: arithmetic. Pure, zero-authority — like every builtin."
  alias Substrate.Lisp.Error

  def namespace, do: "math"
  def names, do: ~w(+ - * / quotient remainder modulo increment decrement absolute minimum maximum)

  def call("+", args, _a), do: Enum.sum(args)
  def call("-", [a], _a), do: -a
  def call("-", [a | rest], _a), do: Enum.reduce(rest, a, &(&2 - &1))
  def call("*", args, _a), do: Enum.reduce(args, 1, &(&1 * &2))
  def call("increment", [a], _a), do: a + 1
  def call("decrement", [a], _a), do: a - 1
  def call("absolute", [a], _a), do: abs(a)
  def call("minimum", args, _a), do: Enum.min(args)
  def call("maximum", args, _a), do: Enum.max(args)

  # division / modulo — a zero divisor is a clean fault, never a crash
  def call("/", [_a, b], _ap) when b == 0, do: raise(Error, "division by zero")
  def call("/", [a, b], _ap), do: a / b
  def call("quotient", [_a, 0], _ap), do: raise(Error, "division by zero")
  def call("quotient", [a, b], _ap), do: div(a, b)
  def call("remainder", [_a, 0], _ap), do: raise(Error, "division by zero")
  def call("remainder", [a, b], _ap), do: rem(a, b)
  def call("modulo", [_a, 0], _ap), do: raise(Error, "division by zero")
  def call("modulo", [a, b], _ap), do: Integer.mod(a, b)
end
