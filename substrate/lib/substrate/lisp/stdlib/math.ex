defmodule Substrate.Lisp.Stdlib.Math do
  @moduledoc "Stdlib group: arithmetic. Pure, zero-authority — like every builtin."
  alias Substrate.Lisp.Error

  def names, do: ~w(+ - * / quot rem mod inc dec abs min max)

  def call("+", args, _a), do: Enum.sum(args)
  def call("-", [a], _a), do: -a
  def call("-", [a | rest], _a), do: Enum.reduce(rest, a, &(&2 - &1))
  def call("*", args, _a), do: Enum.reduce(args, 1, &(&1 * &2))
  def call("inc", [a], _a), do: a + 1
  def call("dec", [a], _a), do: a - 1
  def call("abs", [a], _a), do: abs(a)
  def call("min", args, _a), do: Enum.min(args)
  def call("max", args, _a), do: Enum.max(args)

  # division / modulo — a zero divisor is a clean fault, never a crash
  def call("/", [_a, b], _ap) when b == 0, do: raise(Error, "division by zero")
  def call("/", [a, b], _ap), do: a / b
  def call("quot", [_a, 0], _ap), do: raise(Error, "division by zero")
  def call("quot", [a, b], _ap), do: div(a, b)
  def call("rem", [_a, 0], _ap), do: raise(Error, "division by zero")
  def call("rem", [a, b], _ap), do: rem(a, b)
  def call("mod", [_a, 0], _ap), do: raise(Error, "division by zero")
  def call("mod", [a, b], _ap), do: Integer.mod(a, b)
end
