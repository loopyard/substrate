defmodule Substrate.Lisp.Stdlib.Collection do
  @moduledoc """
  Stdlib group: sequences. `count`/`contains?` are polymorphic over lists, maps,
  and (for count) strings. The higher-order ops — `map`/`filter`/`reduce` — call
  back into the evaluator via the `apply` callback to apply a closure; every such
  application still ticks the step budget, so they stay bounded.
  """
  alias Substrate.Lisp.Stdlib

  def namespace, do: "collection"

  def names,
    do: ~w(count first rest nth empty? reverse sort cons conj concat range contains? map filter reduce list)

  def call("list", args, _ap), do: args

  def call("count", [c], _ap) when is_list(c), do: length(c)
  def call("count", [c], _ap) when is_map(c), do: map_size(c)
  def call("count", [s], _ap) when is_binary(s), do: String.length(s)

  def call("first", [[h | _]], _ap), do: h
  def call("first", [[]], _ap), do: nil
  def call("rest", [[_ | t]], _ap), do: t
  def call("rest", [[]], _ap), do: []
  def call("nth", [coll, i], _ap) when is_list(coll), do: Enum.at(coll, i)
  def call("empty?", [c], _ap) when is_list(c), do: c == []

  def call("reverse", [xs], _ap) when is_list(xs), do: Enum.reverse(xs)
  def call("sort", [xs], _ap) when is_list(xs), do: Enum.sort(xs)
  def call("cons", [x, xs], _ap) when is_list(xs), do: [x | xs]
  def call("conj", [xs, x], _ap) when is_list(xs), do: xs ++ [x]
  def call("concat", [a, b], _ap) when is_list(a) and is_list(b), do: a ++ b

  def call("range", [n], _ap) when is_integer(n),
    do: if(n > 0, do: Enum.to_list(0..(n - 1)), else: [])

  def call("range", [a, b], _ap) when is_integer(a) and is_integer(b),
    do: if(b > a, do: Enum.to_list(a..(b - 1)), else: [])

  def call("contains?", [coll, x], _ap) when is_list(coll), do: x in coll
  def call("contains?", [m, k], _ap) when is_map(m), do: Map.has_key?(m, k)

  def call("map", [f, coll], apply), do: Enum.map(coll, &apply.(f, [&1]))
  def call("filter", [f, coll], apply), do: Enum.filter(coll, &Stdlib.truthy?(apply.(f, [&1])))

  def call("reduce", [f, init, coll], apply) when is_list(coll),
    do: Enum.reduce(coll, init, fn x, acc -> apply.(f, [acc, x]) end)
end
