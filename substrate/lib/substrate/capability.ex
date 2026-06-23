defmodule Substrate.Capability do
  @moduledoc """
  A capability — Substrate's unit of authority, the OS syscall. Declared in
  exactly **one place** (the manifest): the docstring, the typed params, the
  return shape, the policy, the example, and the native `bind` are a single
  s-expression. Code = data = docs; they cannot drift.

  This module compiles a manifest's AST into `%Capability{}` structs, and
  renders the **stripped** view the agent sees via `describe` — everything that
  is authority or mechanism (`bind`, the concrete predicates) removed.
  """

  alias Substrate.{Auth, Predicates}

  defstruct [:name, :doc, :params, :returns, :example, :bind, :auth, policy: []]

  @type t :: %__MODULE__{}

  # --- compile a whole manifest ---
  #
  # A substrate body is capability forms plus optional config forms that bind the
  # vault *in the file*: `(resource :key <literal>)` for a non-secret value (an
  # allowlist), `(secret :key (env "VAR"))` for one pulled from the environment
  # at load. Both feed the L0 credentials; neither is ever rendered to the agent.
  #
  #   (substrate <ns> "doc"
  #     (resource :http-allow ["api.github.com"])
  #     (secret   :gh-token   (env "GITHUB_TOKEN"))
  #     (capability …) …)

  def compile_manifest({:list, [{:sym, "substrate"}, {:sym, ns}, {:str, doc} | forms]}) do
    {caps, config} =
      Enum.reduce(forms, {[], %{resources: %{}, secrets: []}}, &collect_form/2)

    {ns, doc, Enum.reverse(caps), %{config | secrets: Enum.reverse(config.secrets)}}
  end

  defp collect_form({:list, [{:sym, "capability"} | _]} = form, {caps, config}),
    do: {[compile_cap(form) | caps], config}

  defp collect_form({:list, [{:sym, "resource"}, {:kw, key}, value]}, {caps, config}),
    do: {caps, %{config | resources: Map.put(config.resources, key, literal(value))}}

  defp collect_form({:list, [{:sym, "secret"}, {:kw, key}, source]}, {caps, config}),
    do: {caps, %{config | secrets: [{key, compile_source(source)} | config.secrets]}}

  # a resource value is plain literal data — string, int, bool, or a list thereof
  defp literal({:str, s}), do: s
  defp literal({:int, n}), do: n
  defp literal({:bool, b}), do: b
  defp literal(nil), do: nil
  defp literal({:vec, items}), do: Enum.map(items, &literal/1)
  defp literal({:list, items}), do: Enum.map(items, &literal/1)

  # a secret source: `(env "VAR")` resolved at load, or a bare string literal (tests)
  defp compile_source({:list, [{:sym, "env"}, {:str, var}]}), do: {:env, var}
  defp compile_source({:str, s}), do: {:lit, s}

  defp compile_cap({:list, [{:sym, "capability"}, {:sym, name}, {:str, doc} | clauses]}) do
    base = %__MODULE__{name: name, doc: doc}
    Enum.reduce(clauses, base, &apply_clause/2)
  end

  defp apply_clause({:list, [{:sym, "params"} | defs]}, cap),
    do: %{cap | params: Enum.map(defs, &compile_param/1)}

  defp apply_clause({:list, [{:sym, "returns"}, shape]}, cap),
    do: %{cap | returns: shape}

  defp apply_clause({:list, [{:sym, "policy"} | rules]}, cap),
    do: %{cap | policy: Enum.map(rules, &compile_rule/1)}

  defp apply_clause({:list, [{:sym, "example"}, ex]}, cap),
    do: %{cap | example: ex}

  defp apply_clause({:list, [{:sym, "bind"}, {:sym, target}]}, cap),
    do: %{cap | bind: compile_bind(target)}

  # (auth (header "Authorization" (str "Bearer " (secret :gh-token)))) — stripped
  # at the wall like `bind`; resolved against the vault per call by the membrane.
  defp apply_clause({:list, [{:sym, "auth"} | _]} = form, cap),
    do: %{cap | auth: Auth.compile(form)}

  defp compile_param({:list, [{:sym, name}, type | rest]}) do
    doc = case rest do
      [{:str, d} | _] -> d
      _ -> nil
    end

    %{name: String.to_atom(name), type: print(type), doc: doc}
  end

  # (rate "20/min") -> {:rate, count, window, guard}   guard = nil | {name, fun}
  defp compile_rule({:list, [{:sym, "rate"}, {:str, spec}]}) do
    {n, w} = parse_rate(spec)
    {:rate, n, w, nil}
  end

  # (rate "5/min" in-data) -> only counts/limits when the guard predicate holds
  defp compile_rule({:list, [{:sym, "rate"}, {:str, spec}, {:sym, guard}]}) do
    {n, w} = parse_rate(spec)
    {:rate, n, w, {guard, Predicates.lookup(guard)}}
  end

  defp compile_rule({:list, [{:sym, "deny-if"}, {:sym, pred}]}),
    do: {:deny_if, pred, Predicates.lookup(pred)}

  defp compile_rule({:list, [{:sym, "confirm-if"}, {:sym, pred}]}),
    do: {:confirm_if, pred, Predicates.lookup(pred)}

  defp parse_rate(spec) do
    [n, unit] = String.split(spec, "/")
    {String.to_integer(n), window_seconds(unit)}
  end

  defp window_seconds("sec"), do: 1
  defp window_seconds("min"), do: 60
  defp window_seconds("hour"), do: 3600
  defp window_seconds("day"), do: 86_400

  # "Substrate.FS.read/2" -> {Substrate.FS, :read}
  defp compile_bind(target) do
    [mfa, _arity] = String.split(target, "/")
    parts = String.split(mfa, ".")
    {fun, modparts} = List.pop_at(parts, -1)
    mod = Module.concat(modparts)
    {mod, String.to_atom(fun)}
  end

  # --- describe: the stripped, agent-facing view ---

  @doc "One-line signature for a namespace listing."
  def signature(%__MODULE__{name: name, params: params, returns: returns}) do
    pnames = params |> Enum.map(&Atom.to_string(&1.name)) |> Enum.join(" ")
    "#{name}  (#{pnames})  -> #{print(returns)}"
  end

  @doc """
  Full stripped declaration. No `bind` (native target — unnameable at L2), no
  `auth` (it names secrets), no concrete predicate (mechanism).

  Policy rendering has two postures, set per-mount by `reveal_rules`:

    * **abstract** (default) — the agent learns a rate limit exists and that a
      call *may* be reviewed, never the rule that decides a denial. It discovers
      a `deny-if` boundary the way a process learns a permission error: by
      calling and reading `:denied`.
    * **revealed** (`reveal: true`) — each `deny-if` renders as a `(guard …)`
      with a human/agent-readable gloss of the *rule* ("writes limited to
      allowlisted directories"), so the agent can *reason* instead of probe.
      The **value** (which dirs, which hosts) still never crosses the wall — it
      lives in the vault; only the rule's intent is shown.
  """
  def describe(%__MODULE__{} = c, opts \\ []) do
    reveal = Keyword.get(opts, :reveal, false)

    lines =
      [
        "(capability #{c.name}",
        "  #{inspect(c.doc)}",
        "  (params" <> render_params(c.params) <> ")",
        "  (returns #{print(c.returns)})"
      ] ++ render_policy(c.policy, reveal)

    Enum.join(lines, "\n") <> ")"
  end

  defp render_params(params) do
    Enum.map_join(params, "", fn p ->
      doc = if p.doc, do: " #{inspect(p.doc)}", else: ""
      "\n          (#{p.name} #{p.type}#{doc})"
    end)
  end

  defp render_policy([], _reveal), do: []

  defp render_policy(rules, reveal) do
    inner =
      rules
      |> Enum.map(&abstract_rule(&1, reveal))
      |> Enum.reject(&is_nil/1)

    case inner do
      [] -> []
      [first | rest] ->
        ["  (policy " <> first <> Enum.map_join(rest, "", &("\n           " <> &1)) <> ")"]
    end
  end

  # honest-but-abstract: keep the *fact* of a limit / review, drop the *rule*.
  defp abstract_rule({:rate, n, w, nil}, _r), do: "(rate #{inspect("#{n}/#{unit(w)}")})"
  defp abstract_rule({:rate, n, w, {guard, _}}, _r), do: "(rate #{inspect("#{n}/#{unit(w)}")} #{guard})"
  defp abstract_rule({:confirm_if, _pred, _fun}, _r), do: "(confirm-if human-review)"
  # the rule, never the value: dropped when abstract, glossed when revealed.
  defp abstract_rule({:deny_if, _pred, _fun}, false), do: nil
  defp abstract_rule({:deny_if, pred, _fun}, true), do: "(guard #{inspect(gloss(pred))})"

  # readable intent for each trusted predicate — what it enforces, not what it checks against.
  defp gloss("escapes-jail"), do: "path must stay inside the jail root"
  defp gloss("write-denied"), do: "writes limited to allowlisted directories"
  defp gloss("host-denied"), do: "only allowlisted hosts are reachable"
  defp gloss("outside-safe"), do: "writes outside the safe area need human review"
  defp gloss("in-bulk"), do: "applies within the bulk zone"
  defp gloss("in-data"), do: "applies within the data zone"
  defp gloss("in-published"), do: "applies within the published zone"
  defp gloss("in-archive"), do: "applies within the archive zone"
  defp gloss(other), do: "policy guard: #{other}"

  defp unit(1), do: "sec"
  defp unit(60), do: "min"
  defp unit(3600), do: "hour"
  defp unit(86_400), do: "day"

  # --- minimal AST printer (for returns / example / param types) ---

  def print({:sym, s}), do: s
  def print({:str, s}), do: inspect(s)
  def print({:int, n}), do: Integer.to_string(n)
  def print({:kw, a}), do: ":" <> Atom.to_string(a)
  def print({:bool, b}), do: to_string(b)
  def print(nil), do: "nil"
  def print({:list, items}), do: "(" <> Enum.map_join(items, " ", &print/1) <> ")"
  def print({:vec, items}), do: "[" <> Enum.map_join(items, " ", &print/1) <> "]"
  def print({:map, items}), do: "{" <> Enum.map_join(items, " ", &print/1) <> "}"
end
