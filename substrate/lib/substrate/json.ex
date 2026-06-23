defmodule Substrate.JSON do
  @moduledoc """
  A minimal JSON encoder/decoder — just enough to talk to an HTTP/JSON API from
  inside the substrate's OTP-only world.

  Elixir 1.14 / OTP 25 ships no JSON (`JSON` arrived in Elixir 1.18, `:json` in
  OTP 27), and the substrate keeps **zero external dependencies** by design (see
  `mix.exs`). So rather than pull in `Jason`, this is a small hand-rolled pair:
  `encode/1` over Elixir terms and a recursive-descent `decode/1`. It is not a
  general-purpose library — it covers objects, arrays, strings (with the standard
  escapes incl. `\\uXXXX`), numbers, and the literals — which is all the
  `Substrate.Agent.Anthropic` client needs.

  Decoded objects are maps with **string** keys; encode accepts maps with string
  or atom keys, lists, binaries, numbers, booleans, and `nil`.
  """

  # --- encode ---

  @doc "Encode an Elixir term to a JSON iolist-flattened binary."
  def encode(term), do: term |> enc() |> IO.iodata_to_binary()

  defp enc(nil), do: "null"
  defp enc(true), do: "true"
  defp enc(false), do: "false"
  defp enc(n) when is_integer(n), do: Integer.to_string(n)
  defp enc(n) when is_float(n), do: Float.to_string(n)
  defp enc(a) when is_atom(a), do: enc_string(Atom.to_string(a))
  defp enc(s) when is_binary(s), do: enc_string(s)

  defp enc(list) when is_list(list),
    do: ["[", list |> Enum.map(&enc/1) |> Enum.intersperse(","), "]"]

  defp enc(map) when is_map(map) do
    pairs =
      Enum.map(map, fn {k, v} ->
        key = if is_atom(k), do: Atom.to_string(k), else: k
        [enc_string(key), ":", enc(v)]
      end)

    ["{", Enum.intersperse(pairs, ","), "}"]
  end

  defp enc_string(s), do: [?", escape(s), ?"]

  defp escape(s), do: for(<<c <- s>>, into: [], do: esc_char(c))

  defp esc_char(?"), do: "\\\""
  defp esc_char(?\\), do: "\\\\"
  defp esc_char(?\n), do: "\\n"
  defp esc_char(?\r), do: "\\r"
  defp esc_char(?\t), do: "\\t"
  defp esc_char(?\b), do: "\\b"
  defp esc_char(?\f), do: "\\f"
  defp esc_char(c) when c < 0x20, do: :io_lib.format("\\u~4.16.0b", [c])
  defp esc_char(c), do: c

  # --- decode ---

  @doc """
  Decode a JSON binary into Elixir terms. Returns `{:ok, term}` or
  `{:error, reason}`. Objects decode to string-keyed maps.
  """
  def decode(bin) when is_binary(bin) do
    case value(skip(bin)) do
      {term, rest} ->
        case skip(rest) do
          "" -> {:ok, term}
          _ -> {:error, "trailing data"}
        end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "Decode or raise."
  def decode!(bin) do
    case decode(bin) do
      {:ok, term} -> term
      {:error, reason} -> raise ArgumentError, "invalid JSON: #{reason}"
    end
  end

  defp skip(<<c, rest::binary>>) when c in ~c" \t\n\r", do: skip(rest)
  defp skip(bin), do: bin

  defp value(<<"null", rest::binary>>), do: {nil, rest}
  defp value(<<"true", rest::binary>>), do: {true, rest}
  defp value(<<"false", rest::binary>>), do: {false, rest}
  defp value(<<?", rest::binary>>), do: string(rest, [])
  defp value(<<?[, rest::binary>>), do: array(skip(rest), [])
  defp value(<<?{, rest::binary>>), do: object(skip(rest), %{})
  defp value(<<c, _::binary>> = bin) when c in ~c"-0123456789", do: number(bin)
  defp value(_), do: raise(ArgumentError, "unexpected token")

  # strings — the \uXXXX clause must precede the general escape clause
  defp string(<<?", rest::binary>>, acc),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp string(<<?\\, ?u, h::binary-size(4), rest::binary>>, acc),
    do: string(rest, [<<String.to_integer(h, 16)::utf8>> | acc])

  defp string(<<?\\, c, rest::binary>>, acc), do: string(rest, [unescape(c) | acc])
  defp string(<<c, rest::binary>>, acc), do: string(rest, [c | acc])

  defp unescape(?"), do: ?"
  defp unescape(?\\), do: ?\\
  defp unescape(?/), do: ?/
  defp unescape(?n), do: ?\n
  defp unescape(?r), do: ?\r
  defp unescape(?t), do: ?\t
  defp unescape(?b), do: ?\b
  defp unescape(?f), do: ?\f
  defp unescape(c), do: c

  # arrays
  defp array(<<?], rest::binary>>, acc), do: {Enum.reverse(acc), rest}

  defp array(bin, acc) do
    {val, rest} = value(bin)

    case skip(rest) do
      <<?,, more::binary>> -> array(skip(more), [val | acc])
      <<?], more::binary>> -> {Enum.reverse([val | acc]), more}
      _ -> raise ArgumentError, "expected , or ] in array"
    end
  end

  # objects
  defp object(<<?}, rest::binary>>, acc), do: {acc, rest}

  defp object(<<?", rest::binary>>, acc) do
    {key, rest} = string(rest, [])

    case skip(rest) do
      <<?:, rest::binary>> ->
        {val, rest} = value(skip(rest))

        case skip(rest) do
          <<?,, more::binary>> -> object(skip(more), Map.put(acc, key, val))
          <<?}, more::binary>> -> {Map.put(acc, key, val), more}
          _ -> raise ArgumentError, "expected , or } in object"
        end

      _ ->
        raise ArgumentError, "expected : in object"
    end
  end

  defp object(_, _), do: raise(ArgumentError, "expected string key in object")

  # numbers — grab the numeric run, then int-or-float
  defp number(bin) do
    {digits, rest} = take_number(bin, [])
    s = IO.iodata_to_binary(Enum.reverse(digits))
    num = if String.contains?(s, [".", "e", "E"]), do: parse_float(s), else: String.to_integer(s)
    {num, rest}
  end

  defp take_number(<<c, rest::binary>>, acc) when c in ~c"-+0123456789.eE",
    do: take_number(rest, [c | acc])

  defp take_number(bin, acc), do: {acc, bin}

  defp parse_float(s) do
    # Float.parse tolerates "1e3" only as "1.0e3"; normalise a bare exponent.
    case Float.parse(s) do
      {f, ""} -> f
      _ -> s |> ensure_decimal() |> String.to_float()
    end
  end

  defp ensure_decimal(s) do
    if String.contains?(s, "."), do: s, else: String.replace(s, ~r/[eE]/, ".0e", global: false)
  end
end
