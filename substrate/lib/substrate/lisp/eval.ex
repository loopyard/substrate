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
  alias Substrate.Lisp.{Error, Stdlib}

  @specials ~w(do let for if cond case fn defn def and or describe await break quote grant as)

  # Resource bounds for untrusted evaluation (see `run_guarded/3`). Defaults are
  # generous for real programs and lethal to bombs; override per-call via opts.
  @max_steps 1_000_000
  @max_heap_words 5_000_000
  @timeout_ms 5_000

  @doc "Evaluate a program (one or more top-level forms), returning the last value."
  def run(forms, server) when is_list(forms) do
    {val, _env} = eval_seq(forms, %{}, server)
    val
  end

  @doc """
  Evaluate untrusted forms under hard bounds: a step budget, a per-process heap
  cap (heap + stack), and a wall-clock timeout. Runs in a throwaway monitored
  process so a runaway program (infinite loop, allocation/recursion bomb) is
  killed without touching the caller or the node. Returns the program value, or
  `{:fault, reason}`. `opts`: `:max_steps` (int | nil), `:max_heap` (words),
  `:timeout` (ms).
  """
  def run_guarded(forms, server, opts \\ []) do
    steps   = Keyword.get(opts, :max_steps, @max_steps)
    heap    = Keyword.get(opts, :max_heap, @max_heap_words)
    timeout = Keyword.get(opts, :timeout, @timeout_ms)
    parent  = self()
    ref     = make_ref()

    {pid, mon} =
      :erlang.spawn_opt(
        fn ->
          if is_integer(steps), do: Process.put(:substrate_steps_left, steps)

          outcome =
            try do
              {:ok, run(forms, server)}
            rescue
              e in Error -> {:fault, e.message}
            catch
              :substrate_break -> {:ok, nil}
              :substrate_step_limit -> {:fault, "step budget exceeded (#{steps} steps)"}
            end

          send(parent, {ref, outcome})
        end,
        [:monitor, max_heap_size: %{size: heap, kill: true, error_logger: false}]
      )

    receive do
      {^ref, {:ok, val}} ->
        Process.demonitor(mon, [:flush])
        val

      {^ref, {:fault, msg}} ->
        Process.demonitor(mon, [:flush])
        {:fault, msg}

      {:DOWN, ^mon, :process, ^pid, :killed} ->
        {:fault, "heap limit exceeded (#{heap} words)"}

      {:DOWN, ^mon, :process, ^pid, reason} ->
        {:fault, "evaluation crashed: #{inspect(reason)}"}
    after
      timeout ->
        Process.exit(pid, :kill)
        flush_down(mon)
        {:fault, "evaluation timed out (#{timeout} ms)"}
    end
  end

  defp flush_down(mon) do
    receive do
      {:DOWN, ^mon, :process, _, _} -> :ok
    after
      100 -> :ok
    end
  end

  # Every evaluated node ticks the step budget when one is installed for this
  # process; exhausting it aborts the whole program. Outside a guarded run no
  # budget is set and this is a no-op (keeps direct `run/2` callers unbounded).
  def eval(ast, env, s) do
    case Process.get(:substrate_steps_left) do
      nil -> :ok
      n when n <= 0 -> throw(:substrate_step_limit)
      n -> Process.put(:substrate_steps_left, n - 1)
    end

    do_eval(ast, env, s)
  end

  # --- literals ---
  defp do_eval({:int, n}, env, _s), do: {n, env}
  defp do_eval({:str, s}, env, _s), do: {s, env}
  defp do_eval({:bool, b}, env, _s), do: {b, env}
  defp do_eval(nil, env, _s), do: {nil, env}
  defp do_eval({:kw, a}, env, _s), do: {a, env}

  defp do_eval({:vec, items}, env, s), do: {eval_args(items, env, s), env}

  defp do_eval({:map, items}, env, s) do
    vals = eval_args(items, env, s)
    map = vals |> Enum.chunk_every(2) |> Map.new(fn [k, v] -> {k, v} end)
    {map, env}
  end

  # --- symbols: must be bound; a bare capability name has no value (the wall) ---
  defp do_eval({:sym, name}, env, _s) do
    case Map.fetch(env, name) do
      {:ok, v} -> {v, env}
      :error -> raise Error, "unbound symbol `#{name}`"
    end
  end

  # --- compound forms ---
  defp do_eval({:list, [{:sym, name} | args]} = form, env, s) do
    cond do
      name in @specials -> special(name, args, env, s)
      Server.known?(s, name) -> {capability_call(name, args, env, s), env}
      Stdlib.builtin?(name) -> {Stdlib.invoke(name, eval_args(args, env, s), &apply_fn(&1, &2, s)), env}
      Map.has_key?(env, name) -> {apply_fn(Map.fetch!(env, name), eval_args(args, env, s), s), env}
      true -> raise Error, "unbound symbol `#{name}`" <> bare_form_hint(form)
    end
  end

  # keyword in head position is a map accessor: (:from m)
  defp do_eval({:list, [{:kw, key} | args]}, env, s) do
    case eval_args(args, env, s) do
      [m] when is_map(m) -> {Map.get(m, key), env}
      _ -> raise Error, "keyword accessor `:#{key}` expects one map argument"
    end
  end

  # operator is itself an expression (e.g. an inline fn)
  defp do_eval({:list, [head | args]}, env, s) do
    {callee, env} = eval(head, env, s)
    {apply_fn(callee, eval_args(args, env, s), s), env}
  end

  defp do_eval({:list, []}, env, _s), do: {nil, env}

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
    {{:closure, param_names(params), body, env, %{}}, env}
  end

  defp special("defn", [{:sym, name}, {:vec, params} | body], env, _s) do
    pn = param_names(params)
    closure = {:closure, pn, body, env, %{name => {pn, body}}}
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

  # --- delegation: the agent authors a STRICTLY NARROWER child surface ---
  #
  #   (let [child (grant :caps [fs/read] :fs_allow ["downloads"] :rate "5/min")]
  #     (as child (fs/read :path "downloads/notes.txt")))
  #
  # `grant` asks the trusted server to attenuate this surface; it can only narrow
  # (a request to widen comes back :denied). It returns an opaque child handle —
  # never a credential. `as` runs a sub-program against that child, whose own
  # membrane adjudicates every call independently of the parent's.

  defp special("grant", args, env, s) do
    case Server.attenuate(s, parse_grant(args, env, s)) do
      {:ok, child} -> {{:child, child}, env}
      {:denied, reason} -> {{:disposition, :denied, %{reason: reason}}, env}
    end
  end

  defp special("as", [child_expr | body], env, s) do
    case eval(child_expr, env, s) do
      {{:child, child}, _} -> {elem(eval_seq(body, env, child), 0), env}
      _ -> raise Error, "`as` expects a (grant …) handle as its first argument"
    end
  end

  # grant takes flat keyword args; :caps is a vector of *unevaluated* capability
  # symbols, the rest are evaluated values (allowlist vectors, a rate string).
  defp parse_grant(args, env, s) do
    args
    |> Enum.chunk_every(2)
    |> Enum.reduce(%{caps: nil}, fn
      [{:kw, :caps}, {:vec, syms}], acc ->
        Map.put(acc, :caps, Enum.map(syms, fn {:sym, n} -> n end))

      [{:kw, key}, vexpr], acc ->
        Map.put(acc, key, elem(eval(vexpr, env, s), 0))

      _, _acc ->
        raise Error, "grant takes keyword args, e.g. (grant :caps [fs/read] :fs_allow [\"x\"])"
    end)
  end

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

  # A sequence (program, `do`, fn/let body) is a `letrec*` scope: every `defn`
  # in it is visible to every other (mutual recursion), while non-function
  # bindings still take effect left-to-right. The shared `group` of sibling
  # defns rides on each closure and is re-materialised at call time (apply_fn),
  # so a body resolves its siblings no matter who is called first.
  defp eval_seq(forms, env, s) do
    group = scan_defns(forms)
    Enum.reduce(forms, {nil, env}, fn form, {_v, e} -> eval_seq_form(form, group, e, s) end)
  end

  defp scan_defns(forms) do
    for {:list, [{:sym, "defn"}, {:sym, name}, {:vec, params} | body]} <- forms,
        into: %{},
        do: {name, {param_names(params), body}}
  end

  defp eval_seq_form({:list, [{:sym, "defn"}, {:sym, name}, {:vec, params} | body]}, group, env, _s) do
    closure = {:closure, param_names(params), body, env, group}
    {closure, Map.put(env, name, closure)}
  end

  defp eval_seq_form(form, _group, env, s), do: eval(form, env, s)

  defp eval_args(args, env, s), do: Enum.map(args, fn a -> elem(eval(a, env, s), 0) end)

  defp bind_let([], env, _s), do: env
  defp bind_let([{:sym, name}, expr | rest], env, s) do
    {v, _} = eval(expr, env, s)
    bind_let(rest, Map.put(env, name, v), s)
  end

  defp param_names(params), do: Enum.map(params, fn {:sym, n} -> n end)

  defp apply_fn({:closure, names, body, cenv, group}, argvals, s) do
    if length(names) != length(argvals) do
      raise Error, "arity mismatch: expected #{length(names)}, got #{length(argvals)}"
    end

    # letrec: re-materialise every sibling defn (including self) into the call
    # scope against this closure's captured env, so named self- and mutual
    # recursion resolve. `fn` closures carry an empty group — a no-op here.
    sibs = Map.new(group, fn {n, {ps, b}} -> {n, {:closure, ps, b, cenv, group}} end)
    inner = Enum.zip(names, argvals) |> Map.new() |> then(&Map.merge(Map.merge(cenv, sibs), &1))
    {v, _} = eval_seq(body, inner, s)
    v
  end

  defp apply_fn(other, _argvals, _s),
    do: raise(Error, "not callable: #{Show.form(other)}")

  defp match_clauses([], _val, _env, _s), do: nil

  defp match_clauses([_dangling], _val, _env, _s),
    do: raise(Error, "case: a clause pattern is missing its body")

  # clauses are flat pattern/body pairs:  (:done r) <body> 1 <body> x <body> ...
  defp match_clauses([pattern, body | rest], val, env, s) do
    case match_pattern(pattern, val) do
      {:ok, binds} -> elem(eval(body, Map.merge(env, binds), s), 0)
      :no -> match_clauses(rest, val, env, s)
    end
  end

  # disposition patterns: (:done r) binds the payload, (:done) matches tag only
  defp match_pattern({:list, [{:kw, tag}, {:sym, bind}]}, {:disposition, tag, payload}),
    do: {:ok, %{bind => payload}}

  defp match_pattern({:list, [{:kw, tag}]}, {:disposition, tag, _}), do: {:ok, %{}}

  # literal patterns match by value
  defp match_pattern({:int, n}, n), do: {:ok, %{}}
  defp match_pattern({:str, x}, x), do: {:ok, %{}}
  defp match_pattern({:bool, b}, b), do: {:ok, %{}}
  defp match_pattern(nil, nil), do: {:ok, %{}}
  defp match_pattern({:kw, k}, k), do: {:ok, %{}}

  # `_` ignores; any other bare symbol binds the value (a catch-all default)
  defp match_pattern({:sym, "_"}, _val), do: {:ok, %{}}
  defp match_pattern({:sym, name}, val), do: {:ok, %{name => val}}

  defp match_pattern(_pattern, _val), do: :no

  defp truthy?(v), do: Stdlib.truthy?(v)

  defp bare_form_hint({:list, [{:sym, name} | _]}) do
    if String.contains?(name, "/"),
      do: "  (no such capability — `(describe)` the surface)",
      else: ""
  end
end
