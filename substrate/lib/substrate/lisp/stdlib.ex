defmodule Substrate.Lisp.Stdlib do
  @moduledoc """
  The substrate-Lisp standard library — the pure, **zero-authority** builtins the
  evaluator offers (no I/O, no credentials, no way to reach the world; effects go
  through capabilities at the membrane, never here).

  The functions are split into groups that each own a slice of the surface:

    * `Math`  — `+ - * / quot rem mod inc dec abs min max`
    * `Logic` — `= not < > <= >=`
    * `Coll`  — sequences: `count first rest nth reverse sort cons conj concat
      range contains? map filter reduce list`
    * `Str`   — `str join split upcase downcase starts-with? ends-with?`
    * `Maps`  — `get assoc keys vals`
    * `Json`  — `parse-json to-json`

  This module is the registry the evaluator talks to: it builds the
  name → group table once at compile time and `invoke/3` dispatches. A bad-arity
  call surfaces as a clean fault, not a crash. `truthy?/1` lives here too — the
  one value-semantics primitive both the evaluator (`if`/`cond`/`and`/`or`) and
  `Coll.filter` share, so there is a single source of truth.

  Adding a builtin is local: add a `call/3` clause and its name to a group's
  `names/0`. To expose builtins *namespaced* in the Lisp itself later (e.g.
  `str/split`), the group structure is already the seam to do it.
  """

  alias Substrate.{Lisp.Error, Show}
  alias Substrate.Lisp.Stdlib.{Math, Logic, Coll, Str, Maps, Json}

  @groups [Math, Logic, Coll, Str, Maps, Json]

  # name -> group module, resolved once at compile time
  @table for(g <- @groups, n <- g.names(), into: %{}, do: {n, g})

  @doc "Is `name` a stdlib builtin?"
  def builtin?(name), do: Map.has_key?(@table, name)

  @doc "Every builtin name (for tooling / discovery)."
  def names, do: Map.keys(@table)

  @doc """
  Invoke builtin `name` with evaluated `args`. `apply` is the evaluator's
  closure-applier — `(closure, argvals) -> value` — used by the higher-order
  collection ops; everything else ignores it. A clause mismatch (wrong arity or
  type) becomes a clean fault.
  """
  def invoke(name, args, apply) do
    Map.fetch!(@table, name).call(name, args, apply)
  rescue
    FunctionClauseError -> raise Error, "builtin `#{name}` got bad args: #{Show.form(args)}"
  end

  @doc "The language's notion of truth: everything is true except `false` and `nil`."
  def truthy?(v), do: v != false and v != nil
end
