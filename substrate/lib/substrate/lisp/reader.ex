defmodule Substrate.Lisp.Reader do
  @moduledoc """
  The reader for the substrate Lisp. Turns source text into s-expression AST.

  Homoiconicity (DESIGN fork 1) is the whole point: a capability declaration,
  a call to it, and the agent's own program are all the *same* data shape — so
  the registry can compile a substrate, the membrane can statically inspect a
  call, and the agent can read its action space in the form it writes actions.

  ## Two entry points

    * `read_all/2` / `read_one/2` — the strict path. On any syntax error it
      raises `Error` with an aggregated, *located* message (every problem found,
      each with a caret under the offending character). The harness catches it
      and the agent sees a fault that says exactly what to fix and where.
    * `diagnose/2` — the error-tolerant path. It never stops at the first
      problem and never raises: it recovers past each error and returns
      `{:ok, forms}` or `{:error, diagnostics}`, where each diagnostic is
      `%{message, line, col}`. `format_diagnostics/2` renders them for a human
      or an agent. This is what a REPL, an editor, or an agent's self-repair
      loop wants — see the whole list, point at each one.

  ## Hardening

  This reader parses *untrusted* source (the agent's program), so it is bounded
  by construction:

    * **Source size** — input past `@max_source_bytes` is refused before any work.
    * **Nesting depth** — collections nested past `@max_depth` are refused, so a
      pathological `(((((…` can never blow the parser stack.
    * **Atoms** — in `:existing` mode (the agent path) keywords are interned with
      `String.to_existing_atom/1`, so untrusted input can never mint a new atom
      and exhaust the global, un-GC'd atom table; an unknown keyword is a clean,
      located error (recovery substitutes a placeholder, minting nothing). The
      trusted mount path uses `:create`, since a substrate author legitimately
      declares fresh keyword atoms (`:path`, `:fs_roots`, …).

  AST nodes (carry no position — positions live only in diagnostics):
    {:int, integer}   {:str, binary}   {:kw, atom}   {:sym, binary}
    {:list, [node]}   {:vec, [node]}   {:map, [node]}   {:bool, boolean}   :nil
  """

  alias Substrate.Lisp.Error

  @max_source_bytes 256 * 1024
  @max_depth 256

  @type diagnostic :: %{message: binary, line: pos_integer, col: pos_integer}

  @doc """
  Read all top-level forms. `opts[:atoms]` selects keyword interning: `:create`
  (default, trusted mount) mints atoms; `:existing` (untrusted agent path)
  refuses unknown keywords instead of growing the atom table.

  Raises `Error` with a located, multi-problem message if the source has any
  syntax error.
  """
  def read_all(src, opts \\ []) when is_binary(src) do
    check_size!(src)

    case run_parser(src, opts) do
      {forms, []} -> forms
      {_forms, diags} -> raise Error, format_diagnostics(src, diags)
    end
  end

  def read_one(src, opts \\ []) do
    case read_all(src, opts) do
      [form] -> form
      forms -> {:list, [{:sym, "do"} | forms]}
    end
  end

  @doc """
  Parse `src` and report *every* syntax error, with locations, without raising
  and without stopping at the first one. Returns `{:ok, forms}` when clean, or
  `{:error, diagnostics}` (each `%{message, line, col}`, sorted by position).
  Render with `format_diagnostics/2`.
  """
  @spec diagnose(binary, keyword) :: {:ok, [tuple]} | {:error, [diagnostic]}
  def diagnose(src, opts \\ []) when is_binary(src) do
    if byte_size(src) > @max_source_bytes do
      {:error, [diag("source too large (#{byte_size(src)} bytes > #{@max_source_bytes} limit)", 1, 1)]}
    else
      try do
        case run_parser(src, opts) do
          {forms, []} -> {:ok, forms}
          {_forms, diags} -> {:error, diags}
        end
      rescue
        e in Error -> {:error, [diag(Exception.message(e), 1, 1)]}
      end
    end
  end

  @doc """
  Render diagnostics into a human/agent-readable report: each problem with its
  location, message, the offending source line, and a caret under the column.
  """
  @spec format_diagnostics(binary, [diagnostic]) :: binary
  def format_diagnostics(src, diags) do
    lines = String.split(src, "\n")
    n = length(diags)
    header = "#{n} syntax #{if n == 1, do: "error", else: "errors"}:"
    header <> "\n\n" <> Enum.map_join(diags, "\n\n", &format_one(lines, &1))
  end

  defp format_one(lines, %{message: msg, line: l, col: c}) do
    srcline = Enum.at(lines, l - 1) || ""
    caret = String.duplicate(" ", max(c - 1, 0)) <> "^"

    "  line #{l}, column #{c}: #{msg}\n" <>
      "    #{srcline}\n" <>
      "    #{caret}"
  end

  defp run_parser(src, opts) do
    Process.put(:substrate_atom_mode, Keyword.get(opts, :atoms, :create))

    try do
      {tokens, tdiags} = tokenize(src)
      {forms, diags} = parse_all(tokens, [], tdiags, 0)
      {forms, Enum.sort_by(diags, &{&1.line, &1.col})}
    after
      Process.delete(:substrate_atom_mode)
    end
  end

  defp check_size!(src) do
    if byte_size(src) > @max_source_bytes do
      raise Error, "source too large (#{byte_size(src)} bytes > #{@max_source_bytes} limit)"
    end
  end

  defp diag(message, line, col), do: %{message: message, line: line, col: col}

  # --- tokenizer (position-aware) ---
  #
  # Each token is {kind, value, line, col}; kind is one of :lparen :rparen
  # :lbrack :rbrack :lbrace :rbrace :string :atom. Returns {tokens, diagnostics}
  # — the only tokenizer-level problem is an unterminated string, reported at the
  # opening quote (and recovered by closing the string at end of input).

  defp tokenize(src), do: tok(String.to_charlist(src), 1, 1, [], [])

  defp tok([], _l, _c, acc, diags), do: {Enum.reverse(acc), diags}
  defp tok([?\n | rest], l, _c, acc, diags), do: tok(rest, l + 1, 1, acc, diags)

  defp tok([c | rest], l, col, acc, diags) when c in [?\s, ?\t, ?\r, ?,],
    do: tok(rest, l, col + 1, acc, diags)

  defp tok([?; | rest], l, _col, acc, diags) do
    case drop_line(rest) do
      {rest2, :nl} -> tok(rest2, l + 1, 1, acc, diags)
      {rest2, :eof} -> tok(rest2, l, 1, acc, diags)
    end
  end

  defp tok([?( | rest], l, col, acc, diags), do: tok(rest, l, col + 1, [{:lparen, nil, l, col} | acc], diags)
  defp tok([?) | rest], l, col, acc, diags), do: tok(rest, l, col + 1, [{:rparen, nil, l, col} | acc], diags)
  defp tok([?[ | rest], l, col, acc, diags), do: tok(rest, l, col + 1, [{:lbrack, nil, l, col} | acc], diags)
  defp tok([?] | rest], l, col, acc, diags), do: tok(rest, l, col + 1, [{:rbrack, nil, l, col} | acc], diags)
  defp tok([?{ | rest], l, col, acc, diags), do: tok(rest, l, col + 1, [{:lbrace, nil, l, col} | acc], diags)
  defp tok([?} | rest], l, col, acc, diags), do: tok(rest, l, col + 1, [{:rbrace, nil, l, col} | acc], diags)
  defp tok([?" | rest], l, col, acc, diags), do: read_string(rest, [], l, col + 1, l, col, acc, diags)

  defp tok(chars, l, col, acc, diags) do
    {tokstr, rest, n} = read_atom(chars, [], 0)
    tok(rest, l, col + n, [{:atom, tokstr, l, col} | acc], diags)
  end

  defp drop_line([]), do: {[], :eof}
  defp drop_line([?\n | rest]), do: {rest, :nl}
  defp drop_line([_ | rest]), do: drop_line(rest)

  defp read_string([?\\, ?" | rest], buf, l, c, sl, sc, acc, diags), do: read_string(rest, [?" | buf], l, c + 2, sl, sc, acc, diags)
  defp read_string([?\\, ?n | rest], buf, l, c, sl, sc, acc, diags), do: read_string(rest, [?\n | buf], l, c + 2, sl, sc, acc, diags)
  defp read_string([?\\, ?t | rest], buf, l, c, sl, sc, acc, diags), do: read_string(rest, [?\t | buf], l, c + 2, sl, sc, acc, diags)
  defp read_string([?\\, ?\\ | rest], buf, l, c, sl, sc, acc, diags), do: read_string(rest, [?\\ | buf], l, c + 2, sl, sc, acc, diags)

  defp read_string([?" | rest], buf, l, c, sl, sc, acc, diags) do
    tok(rest, l, c + 1, [{:string, finish_string(buf), sl, sc} | acc], diags)
  end

  defp read_string([?\n | rest], buf, l, _c, sl, sc, acc, diags), do: read_string(rest, [?\n | buf], l + 1, 1, sl, sc, acc, diags)
  defp read_string([ch | rest], buf, l, c, sl, sc, acc, diags), do: read_string(rest, [ch | buf], l, c + 1, sl, sc, acc, diags)

  defp read_string([], buf, _l, _c, sl, sc, acc, diags) do
    d = diag("unterminated string — opened here, reached end of input with no closing quote", sl, sc)
    {Enum.reverse([{:string, finish_string(buf), sl, sc} | acc]), [d | diags]}
  end

  defp finish_string(buf), do: buf |> Enum.reverse() |> List.to_string()

  @delims [?\s, ?\t, ?\n, ?\r, ?,, ?(, ?), ?[, ?], ?{, ?}, ?;, ?"]
  defp read_atom([c | rest], buf, n) when c in @delims, do: {atom_str(buf), [c | rest], n}
  defp read_atom([], buf, n), do: {atom_str(buf), [], n}
  defp read_atom([c | rest], buf, n), do: read_atom(rest, [c | buf], n + 1)
  defp atom_str(buf), do: buf |> Enum.reverse() |> List.to_string()

  # --- parser (depth-bounded, error-recovering) ---
  #
  # Threads a diagnostics accumulator and recovers from every syntax slip so a
  # single pass finds them all: an extra closer is skipped, an unclosed opener is
  # closed at its problem site, a mismatched closer closes the current form. Each
  # leaves a located diagnostic behind. Depth is the one hard limit — it raises,
  # because it is a resource bound, not a typo to point at.

  defp parse_all([], acc, diags, _d), do: {Enum.reverse(acc), diags}

  defp parse_all([{closer, _v, l, c} | rest], acc, diags, d) when closer in [:rparen, :rbrack, :rbrace] do
    d2 = diag("unexpected `#{closer_char(closer)}` — nothing is open to close here", l, c)
    parse_all(rest, acc, [d2 | diags], d)
  end

  defp parse_all(tokens, acc, diags, d) do
    {node, rest, diags} = parse(tokens, d, diags)
    parse_all(rest, [node | acc], diags, d)
  end

  defp parse([{:lparen, _v, l, c} | rest], d, diags), do: parse_seq(rest, :rparen, :list, [], deeper(d), l, c, diags)
  defp parse([{:lbrack, _v, l, c} | rest], d, diags), do: parse_seq(rest, :rbrack, :vec, [], deeper(d), l, c, diags)
  defp parse([{:lbrace, _v, l, c} | rest], d, diags), do: parse_seq(rest, :rbrace, :map, [], deeper(d), l, c, diags)
  defp parse([{:string, s, _l, _c} | rest], _d, diags), do: {{:str, s}, rest, diags}

  defp parse([{:atom, a, l, c} | rest], _d, diags) do
    {node, diags} = classify(a, l, c, diags)
    {node, rest, diags}
  end

  defp parse([{closer, _v, l, c} | rest], _d, diags) when closer in [:rparen, :rbrack, :rbrace],
    do: {nil, rest, [diag("unexpected `#{closer_char(closer)}`", l, c) | diags]}

  defp parse([], _d, diags), do: {nil, [], diags}

  defp deeper(d) when d >= @max_depth, do: raise(Error, "nesting too deep (> #{@max_depth})")
  defp deeper(d), do: d + 1

  defp parse_seq([{closer, _v, _l, _c} | rest], closer, tag, acc, _d, _ol, _oc, diags),
    do: {{tag, Enum.reverse(acc)}, rest, diags}

  defp parse_seq([], _closer, tag, acc, _d, ol, oc, diags) do
    d = diag("unclosed `#{opener_char(tag)}` — opened here, reached end of input with no matching `#{matching_close(tag)}`", ol, oc)
    {{tag, Enum.reverse(acc)}, [], [d | diags]}
  end

  defp parse_seq([{other, _v, l, c} | rest], _closer, tag, acc, _d, ol, oc, diags)
       when other in [:rparen, :rbrack, :rbrace] do
    d =
      diag(
        "mismatched delimiter: `#{opener_char(tag)}` opened at line #{ol}, column #{oc} is closed by `#{closer_char(other)}` — expected `#{matching_close(tag)}`",
        l,
        c
      )

    {{tag, Enum.reverse(acc)}, rest, [d | diags]}
  end

  defp parse_seq(tokens, closer, tag, acc, d, ol, oc, diags) do
    {node, rest, diags} = parse(tokens, d, diags)
    parse_seq(rest, closer, tag, [node | acc], d, ol, oc, diags)
  end

  defp classify("nil", _l, _c, diags), do: {nil, diags}
  defp classify("true", _l, _c, diags), do: {{:bool, true}, diags}
  defp classify("false", _l, _c, diags), do: {{:bool, false}, diags}
  defp classify(":" <> name, l, c, diags), do: intern_kw(name, l, c, diags)

  defp classify(tok, _l, _c, diags) do
    case Integer.parse(tok) do
      {n, ""} -> {{:int, n}, diags}
      _ -> {{:sym, tok}, diags}
    end
  end

  defp intern_kw(name, l, c, diags) do
    case Process.get(:substrate_atom_mode, :create) do
      :create ->
        {{:kw, String.to_atom(name)}, diags}

      :existing ->
        try do
          {{:kw, String.to_existing_atom(name)}, diags}
        rescue
          ArgumentError ->
            d =
              diag(
                "unknown keyword `:#{name}` — a program may only use keywords already on the surface; use a string for free-form data keys",
                l,
                c
              )

            {{:str, ":" <> name}, [d | diags]}
        end
    end
  end

  defp closer_char(:rparen), do: ")"
  defp closer_char(:rbrack), do: "]"
  defp closer_char(:rbrace), do: "}"

  defp opener_char(:list), do: "("
  defp opener_char(:vec), do: "["
  defp opener_char(:map), do: "{"

  defp matching_close(:list), do: ")"
  defp matching_close(:vec), do: "]"
  defp matching_close(:map), do: "}"
end
