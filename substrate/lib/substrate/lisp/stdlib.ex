defmodule Substrate.Lisp.Stdlib do
  @moduledoc """
  The substrate-Lisp standard library — the pure, **zero-authority** builtins the
  evaluator offers (no I/O, no credentials, no way to reach the world; effects go
  through capabilities at the membrane, never here).

  The functions are split into groups that each own a slice of the surface:

    * `Math`  — `+ - * / quotient remainder modulo increment decrement absolute minimum maximum`
    * `Logic` — `= not < > <= >=`
    * `Collection`  — sequences: `count first rest element-at reverse sort prepend append concatenate
      range contains? map filter reduce list`
    * `String`  — `string join split uppercase lowercase starts-with? ends-with?`
    * `Maps`  — `get associate keys values`
    * `Json`  — `parse-json to-json`

  This module is the registry the evaluator talks to: it builds the
  name → group table once at compile time and `invoke/3` dispatches. A bad-arity
  call surfaces as a clean fault, not a crash. `truthy?/1` lives here too — the
  one value-semantics primitive both the evaluator (`if`/`cond`/`and`/`or`) and
  `Collection.filter` share, so there is a single source of truth.

  Adding a builtin is local: add a `call/3` clause and its name to a group's
  `names/0`. To expose builtins *namespaced* in the Lisp itself later (e.g.
  `string/split`), the group structure is already the seam to do it.
  """

  alias Substrate.{Lisp.Error, Show}
  alias Substrate.Lisp.Stdlib.{Math, Logic, Collection, String, Maps, Json}

  @groups [Math, Logic, Collection, String, Maps, Json]

  # lookup-name -> {group, bare-name}, resolved once at compile time. Each
  # builtin is reachable two ways: bare (auto-referred, e.g. `reduce`) and
  # namespaced (`collection/reduce`). The namespaced form always reaches the builtin
  # even when a user `defn` shadows the bare name — so a collision is never a
  # dead end.
  @table Enum.reduce(@groups, %{}, fn g, acc ->
           Enum.reduce(g.names(), acc, fn n, acc ->
             acc |> Map.put(n, {g, n}) |> Map.put("#{g.namespace()}/#{n}", {g, n})
           end)
         end)

  @doc "Is `name` a stdlib builtin (bare or `ns/name`)?"
  def builtin?(name), do: Map.has_key?(@table, name)

  @doc "Every builtin lookup name — bare and namespaced (for tooling / discovery)."
  def names, do: Map.keys(@table)

  @doc "The stdlib namespaces, in surface order."
  def namespaces, do: Enum.map(@groups, & &1.namespace())

  @doc """
  Invoke builtin `name` (bare or `ns/name`) with evaluated `args`. `apply` is the
  evaluator's closure-applier — `(closure, argvals) -> value` — used by the
  higher-order collection ops; everything else ignores it. A clause mismatch
  (wrong arity or type) becomes a clean fault.
  """
  def invoke(name, args, apply) do
    {mod, bare} = Map.fetch!(@table, name)
    mod.call(bare, args, apply)
  rescue
    FunctionClauseError -> raise Error, "builtin `#{name}` got bad args: #{Show.form(args)}"
  end

  @doc "The language's notion of truth: everything is true except `false` and `nil`."
  def truthy?(v), do: v != false and v != nil
end
