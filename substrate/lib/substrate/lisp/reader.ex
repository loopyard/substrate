defmodule Substrate.Lisp.Reader do
  @moduledoc """
  The reader for the substrate Lisp. Turns source text into s-expression AST.

  Homoiconicity (DESIGN fork 1) is the whole point: a capability declaration,
  a call to it, and the agent's own program are all the *same* data shape — so
  the registry can compile a substrate, the membrane can statically inspect a
  call, and the agent can read its action space in the form it writes actions.

  AST nodes:
    {:int, integer}   {:str, binary}   {:kw, atom}   {:sym, binary}
    {:list, [node]}   {:vec, [node]}   {:map, [node]}   {:bool, boolean}   :nil
  """

  def read_all(src) do
    src |> tokenize() |> parse_all([])
  end

  def read_one(src) do
    case read_all(src) do
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
  defp read_string([], _buf, _acc), do: raise(Substrate.Lisp.Error, "unterminated string")

  @delims [?\s, ?\t, ?\n, ?\r, ?,, ?(, ?), ?[, ?], ?{, ?}, ?;, ?"]
  defp read_atom([c | rest], buf) when c in @delims, do: {atom_str(buf), [c | rest]}
  defp read_atom([], buf), do: {atom_str(buf), []}
  defp read_atom([c | rest], buf), do: read_atom(rest, [c | buf])
  defp atom_str(buf), do: buf |> Enum.reverse() |> List.to_string()

  # --- parser ---

  defp parse_all([], acc), do: Enum.reverse(acc)
  defp parse_all(tokens, acc) do
    {node, rest} = parse(tokens)
    parse_all(rest, [node | acc])
  end

  defp parse([:lparen | rest]), do: parse_seq(rest, :rparen, :list, [])
  defp parse([:lbrack | rest]), do: parse_seq(rest, :rbrack, :vec, [])
  defp parse([:lbrace | rest]), do: parse_seq(rest, :rbrace, :map, [])
  defp parse([{:string, s} | rest]), do: {{:str, s}, rest}
  defp parse([{:atom, a} | rest]), do: {classify(a), rest}
  defp parse([closer | _]) when closer in [:rparen, :rbrack, :rbrace],
    do: raise(Substrate.Lisp.Error, "unexpected #{closer}")
  defp parse([]), do: raise(Substrate.Lisp.Error, "unexpected end of input")

  defp parse_seq([closer | rest], closer, tag, acc),
    do: {{tag, Enum.reverse(acc)}, rest}
  defp parse_seq([], _closer, _tag, _acc),
    do: raise(Substrate.Lisp.Error, "unterminated list")
  defp parse_seq(tokens, closer, tag, acc) do
    {node, rest} = parse(tokens)
    parse_seq(rest, closer, tag, [node | acc])
  end

  defp classify("nil"), do: nil
  defp classify("true"), do: {:bool, true}
  defp classify("false"), do: {:bool, false}
  defp classify(":" <> name), do: {:kw, String.to_atom(name)}
  defp classify(tok) do
    case Integer.parse(tok) do
      {n, ""} -> {:int, n}
      _ -> {:sym, tok}
    end
  end
end
