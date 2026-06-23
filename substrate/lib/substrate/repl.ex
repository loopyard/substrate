defmodule Substrate.Repl do
  @moduledoc """
  An interactive console for a live substrate — the untrusted **L3** harness as a
  REPL. You attach over stdio and type substrate-Lisp; each complete form is
  evaluated through `Substrate.eval/2`, the *exact* untrusted entry an agent
  uses. So the wall you hit here is the real one: atom-safe reader,
  resource-bounded evaluator (step budget + heap cap + timeout), capabilities the
  only path to the world. Values and dispositions are rendered by
  `Substrate.Show`; multi-line text (e.g. `(describe)`) is printed verbatim.

  This is the "interact with a *loaded* substrate" console. Its sibling
  `Substrate.Console` is the trusted **L2** side — where you *build and debug* a
  substrate. The two are the same wall seen from opposite sides, and both run on
  `Substrate.Repl.Core`.

  Meta-commands use a leading `\\`, which the Lisp reader never produces:

      \\help            this help
      \\caps            describe the whole surface  (same as `(describe)`)
      \\audit           the membrane's audit log, oldest first
      \\quit  \\q        leave  (Ctrl-D also works)
  """

  alias Substrate.Server
  alias Substrate.Repl.Core

  @doc "Run the read-eval-print loop against a running substrate `server`."
  def loop(server, device \\ :stdio) do
    banner(server)
    Core.loop(server, %{prompt: "substrate> ", cont: "      ... ", meta: &meta/2}, device)
  end

  # --- meta commands (the L3 surface: only introspection) ---

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

  defp meta(server, "\\caps"), do: IO.puts(Core.indent(Server.describe(server, nil)))

  defp meta(server, "\\audit"), do: Core.print_audit(server)

  defp meta(_server, other), do: IO.puts("unknown command #{other} — try \\help")

  # --- presentation ---

  defp banner(server) do
    IO.puts("")
    IO.puts(Core.paint(36, "substrate REPL") <> Core.paint(90, "  —  (describe) the surface · \\help for commands · \\q to quit"))
    IO.puts("")
    IO.puts(Core.indent(Server.describe(server, nil)))
    IO.puts("")
  end
end
