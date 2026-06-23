defmodule Substrate.Repl do
  @moduledoc """
  An interactive console for a live substrate — the L3 harness as a REPL.

  You attach over stdio and type substrate-Lisp; each complete form is evaluated
  through `Substrate.eval/2`, the *exact* untrusted entry an agent uses. So the
  wall you hit here is the real one: atom-safe reader, resource-bounded evaluator
  (step budget + heap cap + timeout), capabilities the only path to the world.
  Values and dispositions are rendered by `Substrate.Show`; multi-line text
  (e.g. `(describe)`) is printed verbatim.

  Meta-commands use a leading `\\`, which the Lisp reader never produces:

      \\help            this help
      \\caps            describe the whole surface  (same as `(describe)`)
      \\audit           the membrane's audit log, oldest first
      \\quit  \\q        leave  (Ctrl-D also works)
  """

  alias Substrate.{Show, Server}
  alias Substrate.Lisp.{Reader, Error}

  @prompt "substrate> "
  @cont   "      ... "

  @doc "Run the read-eval-print loop against a running substrate `server`."
  def loop(server, device \\ :stdio) do
    banner(server)
    rep(server, "", device)
  end

  defp rep(server, pending, device) do
    prompt = if pending == "", do: @prompt, else: @cont

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
            if meta(server, trimmed) == :quit, do: :ok, else: rep(server, "", device)

          trimmed == "" ->
            rep(server, "", device)

          # open paren/bracket/brace/string -> keep reading more lines
          incomplete?(buffer) ->
            rep(server, buffer, device)

          true ->
            evaluate(server, buffer)
            rep(server, "", device)
        end
    end
  end

  # --- evaluate one complete chunk through the real untrusted seam ---

  defp evaluate(server, src) do
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

  # --- meta commands ---

  defp meta(_server, cmd) when cmd in ["\\quit", "\\q", "\\exit"], do: :quit

  defp meta(_server, "\\help") do
    IO.puts("""
      \\help    this help
      \\caps    describe the whole surface  (same as (describe))
      \\audit   the membrane's audit log, oldest first
      \\quit    leave  (also \\q, Ctrl-D)

      everything else is substrate-Lisp, e.g.
        (describe)
        (describe fs/write)
        (fs/write :path "/home/agent/notes.txt" :content "hi")
    """)
  end

  defp meta(server, "\\caps"), do: IO.puts(indent(Server.describe(server, nil)))

  defp meta(server, "\\audit") do
    case Server.audit(server) do
      [] ->
        IO.puts("  (no calls adjudicated yet)")

      entries ->
        Enum.each(entries, fn %{seq: n, cap: cap, outcome: out} ->
          IO.puts("  ##{n}  #{cap}  ->  #{outcome_str(out)}")
        end)
    end
  end

  defp meta(_server, other), do: IO.puts("unknown command #{other} — try \\help")

  defp outcome_str({tag, nil}), do: ":#{tag}"
  defp outcome_str({tag, reason}), do: ":#{tag} (#{reason})"
  defp outcome_str(other), do: inspect(other)

  # --- presentation ---

  defp banner(server) do
    IO.puts("")
    IO.puts(paint(36, "substrate REPL") <> paint(90, "  —  (describe) the surface · \\help for commands · \\q to quit"))
    IO.puts("")
    IO.puts(indent(Server.describe(server, nil)))
    IO.puts("")
  end

  defp indent(text),
    do: text |> String.split("\n") |> Enum.map_join("\n", &("  " <> &1))

  defp paint(code, text), do: "\e[#{code}m#{text}\e[0m"
end
