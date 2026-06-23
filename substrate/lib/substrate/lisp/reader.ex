defmodule Substrate.Lisp.Reader do
  @moduledoc """
  The reader for the substrate Lisp. Turns source text into s-expression AST.

  Homoiconicity (DESIGN fork 1) is the whole point: a capability declaration,
  a call to it, and the agent's own program are all the *same* data shape — so
  the registry can compile a substrate, the membrane can statically inspect a
  call, and the agent can read its action space in the form it writes actions.

  ## Hardening

  This reader parses *untrusted* source (the agent's program), so it is bounded
  by construction:

    * **Source size** — input past `@max_source_bytes` is refused before any work.
    * **Nesting depth** — collections nested past `@max_depth` are refused, so a
      pathological `(((((…` can never blow the parser stack.
    * **Atoms** — in `:existing` mode (the agent path) keywords are interned with
      `String.to_existing_atom/1`, so untrusted input can never mint a new atom
      and exhaust the global, un-GC'd atom table; an unknown keyword is a clean
      fault. The trusted mount path uses `:create`, since a substrate author
      legitimately declares fresh keyword atoms (`:path`, `:fs_roots`, …).

  AST nodes:
    {:int, integer}   {:str, binary}   {:kw, atom}   {:sym, binary}
    {:list, [node]}   {:vec, [node]}   {:map, [node]}   {:bool, boolean}   :nil
  """

  alias Substrate.Lisp.Error

  @max_source_bytes 256 * 1024
  @max_depth 256

  @doc """
  Read all top-level forms. `opts[:atoms]` selects keyword interning: `:create`
  (default, trusted mount) mints atoms; `:existing` (untrusted agent path)
  refuses unknown keywords instead of growing the atom table.
  """
  def read_all(src, opts \\ []) when is_binary(src) do
    if byte_size(src) > @max_source_bytes do
      raise Error, "source too large (#{byte_size(src)} bytes > #{@max_source_bytes} limit)"
    end

    Process.put(:substrate_atom_mode, Keyword.get(opts, :atoms, :create))

    try do
      src |> tokenize() |> parse_all([])
    after
      Process.delete(:substrate_atom_mode)
    end
  end

  def read_one(src, opts \\ []) do
    case read_all(src, opts) do
      [form] -> form
      forms -> {:list, [{:sym, "do"} | forms]}
    end
  end

  # --- tokenizer ---

  defp tokenize(src), do: tok(String.to_charlist(src), [])

  defp tok([], acc), do: Enum.reverse(acc)
  # whitespace + commas are separators
  defp tok([c | rest], acc) when c in [?\s, ?\t, ?\n, ?\r, ?,], do: tok(rest, acc)
  # comments to end of line
  defp tok([?; | rest], acc), do: tok(drop_line(rest), acc)
  defp tok([?( | rest], acc), do: tok(rest, [:lparen | acc])
  defp tok([?) | rest], acc), do: tok(rest, [:rparen | acc])
  defp tok([?[ | rest], acc), do: tok(rest, [:lbrack | acc])
  defp tok([?] | rest], acc), do: tok(rest, [:rbrack | acc])
  defp tok([?{ | rest], acc), do: tok(rest, [:lbrace | acc])
  defp tok([?} | rest], acc), do: tok(rest, [:rbrace | acc])
  defp tok([?" | rest], acc), do: read_string(rest, [], acc)

  defp tok(chars, acc) do
    {tokstr, rest} = read_atom(chars, [])
    tok(rest, [{:atom, tokstr} | acc])
  end

  defp drop_line([]), do: []
  defp drop_line([?\n | rest]), do: rest
  defp drop_line([_ | rest]), do: drop_line(rest)

  defp read_string([?\\, ?" | rest], buf, acc), do: read_string(rest, [?" | buf], acc)
  defp read_string([?\\, ?n | rest], buf, acc), do: read_string(rest, [?\n | buf], acc)
  defp read_string([?\\, ?t | rest], buf, acc), do: read_string(rest, [?\t | buf], acc)
  defp read_string([?\\, ?\\ | rest], buf, acc), do: read_string(rest, [?\\ | buf], acc)
  defp read_string([?" | rest], buf, acc) do
    str = buf |> Enum.reverse() |> List.to_string()
    tok(rest, [{:string, str} | acc])
  end
  defp read_string([c | rest], buf, acc), do: read_string(rest, [c | buf], acc)
  defp read_string([], _buf, _acc), do: raise(Error, "unterminated string")

  @delims [?\s, ?\t, ?\n, ?\r, ?,, ?(, ?), ?[, ?], ?{, ?}, ?;, ?"]
  defp read_atom([c | rest], buf) when c in @delims, do: {atom_str(buf), [c | rest]}
  defp read_atom([], buf), do: {atom_str(buf), []}
  defp read_atom([c | rest], buf), do: read_atom(rest, [c | buf])
  defp atom_str(buf), do: buf |> Enum.reverse() |> List.to_string()

  # --- parser (depth-bounded) ---

  defp parse_all([], acc), do: Enum.reverse(acc)
  defp parse_all(tokens, acc) do
    {node, rest} = parse(tokens, 0)
    parse_all(rest, [node | acc])
  end

  defp parse([:lparen | rest], d), do: parse_seq(rest, :rparen, :list, [], deeper(d))
  defp parse([:lbrack | rest], d), do: parse_seq(rest, :rbrack, :vec, [], deeper(d))
  defp parse([:lbrace | rest], d), do: parse_seq(rest, :rbrace, :map, [], deeper(d))
  defp parse([{:string, s} | rest], _d), do: {{:str, s}, rest}
  defp parse([{:atom, a} | rest], _d), do: {classify(a), rest}
  defp parse([closer | _], _d) when closer in [:rparen, :rbrack, :rbrace],
    do: raise(Error, "unexpected #{closer}")
  defp parse([], _d), do: raise(Error, "unexpected end of input")

  defp deeper(d) when d >= @max_depth, do: raise(Error, "nesting too deep (> #{@max_depth})")
  defp deeper(d), do: d + 1

  defp parse_seq([closer | rest], closer, tag, acc, _d),
    do: {{tag, Enum.reverse(acc)}, rest}
  defp parse_seq([], _closer, _tag, _acc, _d),
    do: raise(Error, "unterminated list")
  defp parse_seq(tokens, closer, tag, acc, d) do
    {node, rest} = parse(tokens, d)
    parse_seq(rest, closer, tag, [node | acc], d)
  end

  defp classify("nil"), do: nil
  defp classify("true"), do: {:bool, true}
  defp classify("false"), do: {:bool, false}
  defp classify(":" <> name), do: {:kw, intern_kw(name)}
  defp classify(tok) do
    case Integer.parse(tok) do
      {n, ""} -> {:int, n}
      _ -> {:sym, tok}
    end
  end

  # Keyword interning, gated by mode (see moduledoc). `:existing` never grows the
  # atom table — an unknown keyword from untrusted input is a clean fault.
  defp intern_kw(name) do
    case Process.get(:substrate_atom_mode, :create) do
      :create ->
        String.to_atom(name)

      :existing ->
        try do
          String.to_existing_atom(name)
        rescue
          ArgumentError ->
            raise Error,
                  "unknown keyword `:#{name}` — a program may only use keywords already " <>
                    "on the surface; use a string for free-form data keys"
        end
    end
  end
end
