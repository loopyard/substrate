defmodule Substrate.Repl.Core do
  @moduledoc """
  The shared read-eval-print machinery behind both consoles — the multi-line
  reader, the L3 eval seam, and the presentation helpers.

  The two front ends differ only in their *banner* and their *meta-command
  table*: `Substrate.Repl` is the bare untrusted L3 seam an agent talks to;
  `Substrate.Console` adds the trusted L2 authoring verbs. Both evaluate bare
  input through the **same** `Substrate.eval/2` — the wall is identical; the
  console merely also lets you reach over it.

  `loop/3` is parameterized by a `cfg` map:

      %{prompt: "substrate> ", cont: "      ... ", meta: &meta/2}

  where `meta` is a 2-arity fun `(server, "\\command") -> :quit | any`. A line
  whose first non-space character is `\\` (which the Lisp reader never produces)
  is handed to `meta`; everything else is read as substrate-Lisp and evaluated.
  """

  alias Substrate.Show
  alias Substrate.Lisp.{Reader, Error}

  @doc "Run the read-eval-print loop against `server` with the given `cfg`."
  def loop(server, cfg, device \\ :stdio), do: rep(server, "", cfg, device)

  defp rep(server, pending, cfg, device) do
    prompt = if pending == "", do: cfg.prompt, else: cfg.cont

    case IO.gets(device, prompt) do
      :eof ->
        IO.puts("")
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "input error: #{inspect(reason)}")
        :ok

      data ->
        buffer = pending <> to_string(data)
        trimmed = String.trim(buffer)

        cond do
          pending == "" and String.starts_with?(trimmed, "\\") ->
            if cfg.meta.(server, trimmed) == :quit, do: :ok, else: rep(server, "", cfg, device)

          trimmed == "" ->
            rep(server, "", cfg, device)

          # open paren/bracket/brace/string -> keep reading more lines
          incomplete?(buffer) ->
            rep(server, buffer, cfg, device)

          true ->
            evaluate(server, buffer)
            rep(server, "", cfg, device)
        end
    end
  end

  @doc """
  Evaluate one complete chunk through the real untrusted seam (`Substrate.eval/2`)
  and print the rendered value, multi-line text, or fault.
  """
  def evaluate(server, src) do
    case Substrate.eval(server, src) do
      {:fault, msg} -> IO.puts(paint(31, "  x " <> msg))
      text when is_binary(text) -> IO.puts(indent(text))
      value -> IO.puts("  => " <> Show.form(value))
    end
  end

  # Incomplete == the reader failed *only* because input ran out. Any other
  # parse error is a real fault we let `evaluate` surface.
  defp incomplete?(src) do
    Reader.read_all(src, atoms: :existing)
    false
  rescue
    e in Error ->
      String.contains?(e.message, "unexpected end") or
        String.contains?(e.message, "unterminated")
  end

  @doc "Print the trusted-side audit log, oldest first (shared by both consoles)."
  def print_audit(server) do
    case Substrate.Server.audit(server) do
      [] ->
        IO.puts("  (no calls adjudicated yet)")

      entries ->
        Enum.each(entries, fn %{seq: n, cap: cap, outcome: out} ->
          IO.puts("  ##{n}  #{cap}  ->  #{outcome_str(out)}")
        end)
    end
  end

  defp outcome_str({tag, nil}), do: ":#{tag}"
  defp outcome_str({tag, reason}), do: ":#{tag} (#{reason})"
  defp outcome_str(other), do: inspect(other)

  # --- presentation ---

  @doc "Indent every line of `text` by two spaces."
  def indent(text),
    do: text |> String.split("\n") |> Enum.map_join("\n", &("  " <> &1))

  @doc "Wrap `text` in an ANSI SGR code."
  def paint(code, text), do: "\e[#{code}m#{text}\e[0m"
end
