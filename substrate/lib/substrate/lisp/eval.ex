defmodule Substrate.Lisp.Eval do
  @moduledoc """
  The L2 evaluator — the sandbox the untrusted harness actually runs code in.

  This is a *computer, not a menu* (DESIGN): the agent emits a whole program —
  `let`, `for`, `case`, its own `defn` helpers — that runs against a snapshot of
  the surface, clamped the whole way through. The leap over tool-calling is that
  one emission carries control flow, and the membrane governs every capability
  call inside it.

  The wall is structural, not a blocklist: the environment has **zero ambient
  authority**. There is no `read-file`, no `System/getenv`, no `eval-native`, no
  operation that returns a credential — those symbols have no referent, so they
  resolve to an unbound-symbol fault. Capabilities are the *only* path to the
  world, and each returns a disposition, never a raw effect.

  `eval/3` threads an environment: `eval(ast, env, server) -> {value, env}`.
  """

  alias Substrate.{Server, Show}
  alias Substrate.Lisp.Error

  @specials ~w(do let for if cond case fn defn def and or describe await break quote)

  @doc "Evaluate a program (one or more top-level forms), returning the last value."
  def run(forms, server) when is_list(forms) do
    {val, _env} = eval_seq(forms, %{}, server)
    val
  end

  # --- literals ---
  def eval({:int, n}, env, _s), do: {n, env}
  def eval({:str, s}, env, _s), do: {s, env}
  def eval({:bool, b}, env, _s), do: {b, env}
  def eval(nil, env, _s), do: {nil, env}
  def eval({:kw, a}, env, _s), do: {a, env}

  def eval({:vec, items}, env, s), do: {eval_args(items, env, s), env}

  def eval({:map, items}, env, s) do
    vals = eval_args(items, env, s)
    map = vals |> Enum.chunk_every(2) |> Map.new(fn [k, v] -> {k, v} end)
    {map, env}
  end

  # --- symbols: must be bound; a bare capability name has no value (the wall) ---
  def eval({:sym, name}, env, _s) do
    case Map.fetch(env, name) do
      {:ok, v} -> {v, env}
      :error -> raise Error, "unbound symbol `#{name}`"
    end
  end

  # --- compound forms ---
  def eval({:list, [{:sym, name} | args]} = form, env, s) do
    cond do
      name in @specials -> special(name, args, env, s)
      Server.known?(s, name) -> {capability_call(name, args, env, s), env}
      builtin?(name) -> {apply_builtin(name, eval_args(args, env, s), s), env}
      Map.has_key?(env, name) -> {apply_fn(Map.fetch!(env, name), eval_args(args, env, s), s), env}
      true -> raise Error, "unbound symbol `#{name}`" <> bare_form_hint(form)
    end
  end

  # keyword in head position is a map accessor: (:from m)
  def eval({:list, [{:kw, key} | args]}, env, s) do
    case eval_args(args, env, s) do
      [m] when is_map(m) -> {Map.get(m, key), env}
      _ -> raise Error, "keyword accessor `:#{key}` expects one map argument"
    end
  end

  # operator is itself an expression (e.g. an inline fn)
  def eval({:list, [head | args]}, env, s) do
    {callee, env} = eval(head, env, s)
    {apply_fn(callee, eval_args(args, env, s), s), env}
  end

  def eval({:list, []}, env, _s), do: {nil, env}

  # --- special forms ---

  defp special("do", forms, env, s), do: eval_seq(forms, env, s)

  defp special("let", [{:vec, binds} | body], env, s) do
    inner = bind_let(binds, env, s)
    {val, _} = eval_seq(body, inner, s)
    {val, env}
  end

  defp special("for", [{:vec, [{:sym, var}, coll_expr]} | body], env, s) do
    {coll, _} = eval(coll_expr, env, s)

    result =
      try do
        Enum.map(coll, fn item ->
          {v, _} = eval_seq(body, Map.put(env, var, item), s)
          v
        end)
      catch
        :substrate_break -> :broken
      end

    {if(result == :broken, do: nil, else: result), env}
  end

  defp special("if", [test, then | rest], env, s) do
    {tv, _} = eval(test, env, s)

    cond do
      truthy?(tv) -> {elem(eval(then, env, s), 0), env}
      rest == [] -> {nil, env}
      true -> {elem(eval(hd(rest), env, s), 0), env}
    end
  end

  defp special("cond", clauses, env, s) do
    val =
      Enum.find_value(clauses, fn {:list, [test | body]} ->
        {tv, _} = eval(test, env, s)
        if truthy?(tv), do: {:ok, elem(eval_seq(body, env, s), 0)}
      end)

    {if(val, do: elem(val, 1), else: nil), env}
  end

  defp special("case", [subject | clauses], env, s) do
    {val, _} = eval(subject, env, s)
    {match_clauses(clauses, val, env, s), env}
  end

  defp special("fn", [{:vec, params} | body], env, _s) do
    {{:closure, param_names(params), body, env}, env}
  end

  defp special("defn", [{:sym, name}, {:vec, params} | body], env, _s) do
    closure = {:closure, param_names(params), body, env}
    {closure, Map.put(env, name, closure)}
  end

  defp special("def", [{:sym, name}, expr], env, s) do
    {v, _} = eval(expr, env, s)
    {v, Map.put(env, name, v)}
  end

  defp special("and", args, env, s) do
    {Enum.reduce_while(args, true, fn a, _ ->
       {v, _} = eval(a, env, s)
       if truthy?(v), do: {:cont, v}, else: {:halt, v}
     end), env}
  end

  defp special("or", args, env, s) do
    {Enum.reduce_while(args, nil, fn a, _ ->
       {v, _} = eval(a, env, s)
       if truthy?(v), do: {:halt, v}, else: {:cont, v}
     end), env}
  end

  defp special("describe", args, env, s) do
    target =
      case args do
        [] -> nil
        [{:sym, name}] -> name
      end

    {Server.describe(s, target), env}
  end

  defp special("await", [expr], env, s) do
    {handle, _} = eval(expr, env, s)
    {Server.await(s, handle), env}
  end

  defp special("break", _args, _env, _s), do: throw(:substrate_break)

  defp special("quote", [form], env, _s), do: {form, env}

  # --- capability call: keyword args only; returns a disposition ---

  defp capability_call(name, args, env, s) do
    kwargs = parse_kwargs(name, args, env, s)

    case Server.call(s, name, kwargs) do
      {:disposition, _, _} = disp -> disp
      {:invalid, msg} -> raise Error, "bad call to `#{name}`: #{msg}"
      {:unbound, _} -> raise Error, "unbound symbol `#{name}`"
    end
  end

  defp parse_kwargs(name, args, env, s) do
    args
    |> Enum.chunk_every(2)
    |> Map.new(fn
      [{:kw, k}, vexpr] -> {k, elem(eval(vexpr, env, s), 0)}
      _ -> raise Error, "capability `#{name}` takes keyword args, e.g. (#{name} :path \"x\")"
    end)
  end

  # --- helpers ---

  defp eval_seq(forms, env, s) do
    Enum.reduce(forms, {nil, env}, fn form, {_v, e} -> eval(form, e, s) end)
  end

  defp eval_args(args, env, s), do: Enum.map(args, fn a -> elem(eval(a, env, s), 0) end)

  defp bind_let([], env, _s), do: env
  defp bind_let([{:sym, name}, expr | rest], env, s) do
    {v, _} = eval(expr, env, s)
    bind_let(rest, Map.put(env, name, v), s)
  end

  defp param_names(params), do: Enum.map(params, fn {:sym, n} -> n end)

  defp apply_fn({:closure, names, body, cenv}, argvals, s) do
    if length(names) != length(argvals) do
      raise Error, "arity mismatch: expected #{length(names)}, got #{length(argvals)}"
    end

    inner = Enum.zip(names, argvals) |> Map.new() |> then(&Map.merge(cenv, &1))
    {v, _} = eval_seq(body, inner, s)
    v
  end

  defp apply_fn(other, _argvals, _s),
    do: raise(Error, "not callable: #{Show.form(other)}")

  defp match_clauses([], _val, _env, _s), do: nil

  # clauses are flat pattern/body pairs:  (:done r) <body> (:denied d) <body> ...
  defp match_clauses([pattern, body | rest], val, env, s) do
    case match_pattern(pattern, val) do
      {:ok, binds} -> elem(eval(body, Map.merge(env, binds), s), 0)
      :no -> match_clauses(rest, val, env, s)
    end
  end

  # (:done r) — bind payload to r
  defp match_pattern({:list, [{:kw, tag}, {:sym, bind}]}, {:disposition, tag, payload}),
    do: {:ok, %{bind => payload}}

  # (:done) — match tag, no binding
  defp match_pattern({:list, [{:kw, tag}]}, {:disposition, tag, _}), do: {:ok, %{}}
  # _ — wildcard
  defp match_pattern({:sym, "_"}, _val), do: {:ok, %{}}
  defp match_pattern(_pattern, _val), do: :no

  defp truthy?(v), do: v != false and v != nil

  defp bare_form_hint({:list, [{:sym, name} | _]}) do
    if String.contains?(name, "/"),
      do: "  (no such capability — `(describe)` the surface)",
      else: ""
  end

  # --- builtins: pure stdlib, zero authority ---

  @builtins ~w(str log println count first rest empty? map filter get
               + - * = < > <= >= not inc dec join upcase downcase ends-with? list)

  defp builtin?(name), do: name in @builtins

  defp apply_builtin("str", args, _s), do: Enum.map_join(args, "", &Show.display/1)
  defp apply_builtin("log", args, _s) do
    IO.puts("    [agent] " <> Enum.map_join(args, " ", &Show.display/1))
    nil
  end
  defp apply_builtin("println", args, s), do: apply_builtin("log", args, s)
  defp apply_builtin("count", [c], _s) when is_list(c), do: length(c)
  defp apply_builtin("count", [c], _s) when is_map(c), do: map_size(c)
  defp apply_builtin("first", [[h | _]], _s), do: h
  defp apply_builtin("first", [[]], _s), do: nil
  defp apply_builtin("rest", [[_ | t]], _s), do: t
  defp apply_builtin("rest", [[]], _s), do: []
  defp apply_builtin("empty?", [c], _s) when is_list(c), do: c == []
  defp apply_builtin("list", args, _s), do: args
  defp apply_builtin("map", [f, coll], s), do: Enum.map(coll, &apply_fn(f, [&1], s))
  defp apply_builtin("filter", [f, coll], s), do: Enum.filter(coll, &truthy?(apply_fn(f, [&1], s)))
  defp apply_builtin("get", [m, k], _s) when is_map(m), do: Map.get(m, k)
  defp apply_builtin("+", args, _s), do: Enum.sum(args)
  defp apply_builtin("-", [a], _s), do: -a
  defp apply_builtin("-", [a | rest], _s), do: Enum.reduce(rest, a, &(&2 - &1))
  defp apply_builtin("*", args, _s), do: Enum.reduce(args, 1, &(&1 * &2))
  defp apply_builtin("inc", [a], _s), do: a + 1
  defp apply_builtin("dec", [a], _s), do: a - 1
  defp apply_builtin("=", [a | rest], _s), do: Enum.all?(rest, &(&1 == a))
  defp apply_builtin("<", [a, b], _s), do: a < b
  defp apply_builtin(">", [a, b], _s), do: a > b
  defp apply_builtin("<=", [a, b], _s), do: a <= b
  defp apply_builtin(">=", [a, b], _s), do: a >= b
  defp apply_builtin("not", [a], _s), do: not truthy?(a)
  defp apply_builtin("join", [coll, sep], _s), do: Enum.map_join(coll, sep, &Show.display/1)
  defp apply_builtin("upcase", [str], _s), do: String.upcase(str)
  defp apply_builtin("downcase", [str], _s), do: String.downcase(str)
  defp apply_builtin("ends-with?", [str, suffix], _s), do: String.ends_with?(str, suffix)
  defp apply_builtin(name, args, _s),
    do: raise(Error, "builtin `#{name}` got bad args: #{Show.form(args)}")
end
