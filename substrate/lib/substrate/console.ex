defmodule Substrate.Console do
  @moduledoc """
  The **operator console** — the trusted **L2** side of the wall, for *building
  and debugging* a substrate. Its sibling `Substrate.Repl` is the untrusted L3
  seam an agent talks to; this is where the *author* stands.

  You sit inside the membrane here. Bare input is still evaluated through the
  exact `Substrate.eval/2` seam — so at any moment you can see precisely what the
  agent would get back — but you also hold the authoring verbs the agent never
  can:

    * **build** the surface live — `\\mount FILE` adds a namespace to a running
      session; start from nothing and grow it form by form
    * **debug** it — `\\reveal CAP` X-rays a capability's hidden policy rules;
      `\\audit` is the trusted call log; `\\revoke` / `\\restore` flip a capability
      and let you watch the agent's surface change under it
    * **stand in for the human** at the approval queue — `\\queue` lists effects
      parked for review, `\\approve` / `\\deny` rule on them

  The two consoles are the same wall seen from both sides. Start empty and build
  up, or preload files:

      mix substrate.console
      mix substrate.console priv/substrates/roots.lisp

  Meta-commands use a leading `\\` (which the Lisp reader never produces);
  everything else is substrate-Lisp evaluated as the agent.
  """

  alias Substrate.{Server, Show}
  alias Substrate.Repl.Core

  @prompt "operator> "
  @cont   "     ... "

  @doc "Run the operator console against a running substrate `server`."
  def loop(server, device \\ :stdio) do
    banner(server)
    Core.loop(server, %{prompt: @prompt, cont: @cont, meta: &meta/2}, device)
  end

  # --- meta commands: the trusted L2 verbs ---

  defp meta(_server, cmd) when cmd in ["\\quit", "\\q", "\\exit"], do: :quit

  defp meta(_server, "\\help"), do: IO.puts(help_text())

  # build: mount a substrate file onto the running surface
  defp meta(server, "\\mount" <> rest), do: do_mount(server, rest)

  # inspect: the surface, plain and X-rayed
  defp meta(server, "\\caps"), do: IO.puts(Core.indent(Server.describe(server, nil)))

  defp meta(server, "\\describe" <> rest),
    do: IO.puts(Core.indent(Server.describe(server, target_of(rest))))

  defp meta(server, "\\reveal" <> rest),
    do: IO.puts(Core.indent(Server.reveal(server, target_of(rest))))

  # mutate: suspend / restore a capability (signature stays; it returns :denied)
  defp meta(server, "\\revoke" <> rest), do: flip(server, :revoke, rest)
  defp meta(server, "\\restore" <> rest), do: flip(server, :restore, rest)

  # the approval queue: list, then rule on a parked effect
  defp meta(server, "\\queue"), do: show_queue(server)
  defp meta(server, "\\approve" <> rest), do: resolve(server, :approve, rest)
  defp meta(server, "\\deny" <> rest), do: resolve(server, :deny, rest)

  defp meta(server, "\\audit"), do: Core.print_audit(server)

  defp meta(_server, other), do: IO.puts("unknown command #{String.trim(other)} — try \\help")

  # --- \mount FILE [--reveal] [--cred k=v ...] ---

  defp do_mount(server, rest) do
    {opts, paths, _} =
      rest |> String.split(~r/\s+/, trim: true) |> OptionParser.parse(strict: [reveal: :boolean, cred: :keep])

    case paths do
      [] ->
        IO.puts("  usage: \\mount FILE [more.lisp ...] [--reveal] [--cred k=v]")

      paths ->
        mount_opts = [reveal_rules: Keyword.get(opts, :reveal, false), credentials: parse_creds(opts)]
        Enum.each(paths, &mount_one(server, &1, mount_opts))
        IO.puts("")
        IO.puts(Core.indent(Server.describe(server, nil)))
    end
  end

  defp mount_one(server, path, opts) do
    with {:ok, src} <- File.read(path),
         ast <- Substrate.read_substrate(src),
         :ok <- Server.mount(server, ast, opts) do
      IO.puts(Core.paint(32, "  + mounted #{path}"))
    else
      {:error, reason} -> IO.puts(Core.paint(31, "  x #{path}: #{:file.format_error(reason)}"))
      other -> IO.puts(Core.paint(31, "  x #{path}: #{inspect(other)}"))
    end
  rescue
    e -> IO.puts(Core.paint(31, "  x #{path}: #{Exception.message(e)}"))
  end

  defp parse_creds(opts) do
    opts
    |> Keyword.get_values(:cred)
    |> Map.new(fn kv ->
      case String.split(kv, "=", parts: 2) do
        [k, v] -> {String.to_atom(k), parse_value(v)}
        _ -> {String.to_atom(kv), true}
      end
    end)
  end

  defp parse_value(v), do: if(String.contains?(v, ","), do: String.split(v, ","), else: v)

  # --- revoke / restore ---

  defp flip(_server, _verb, rest) when rest in ["", " "],
    do: IO.puts("  usage: \\revoke NAME  /  \\restore NAME")

  defp flip(server, verb, rest) do
    name = String.trim(rest)
    apply(Server, verb, [server, name])
    tag = if verb == :revoke, do: "revoked", else: "restored"
    IO.puts(Core.paint(33, "  #{tag} #{name}"))
    IO.puts(Core.indent(Server.describe(server, name)))
  end

  # --- approval queue ---

  defp show_queue(server) do
    case Server.pending(server) do
      [] ->
        IO.puts("  (no effects awaiting review)")

      effects ->
        Enum.each(effects, fn {handle, name, args} ->
          IO.puts("  #{handle}  #{name}  #{Show.form(args)}")
        end)

        IO.puts(Core.paint(90, "  — \\approve HANDLE  /  \\deny HANDLE"))
    end
  end

  defp resolve(_server, verb, rest) when rest in ["", " "],
    do: IO.puts("  usage: \\#{verb} HANDLE  (see \\queue)")

  defp resolve(server, verb, rest) do
    handle = String.trim(rest)
    result = apply(Server, verb, [server, handle])
    IO.puts("  => " <> Show.form(result))
  end

  # --- helpers ---

  defp target_of(rest) do
    case String.trim(rest) do
      "" -> nil
      t -> t
    end
  end

  defp help_text do
    """
      \\help                 this help
      \\mount FILE [..]      mount a substrate onto the live surface
                            opts: --reveal  --cred KEY=VALUE (repeatable)
      \\caps                 describe the surface  (same as (describe))
      \\describe [TARGET]    describe a namespace or capability
      \\reveal [TARGET]      describe WITH hidden policy rules — the operator X-ray
      \\revoke NAME          suspend a capability (signature stays; returns :denied)
      \\restore NAME         un-suspend it
      \\queue                effects parked for human review
      \\approve HANDLE       rule: let a queued effect run
      \\deny HANDLE          rule: reject a queued effect
      \\audit                the trusted-side call log, oldest first
      \\quit                 leave  (also \\q, Ctrl-D)

      everything else is substrate-Lisp, evaluated through the SAME seam the
      agent hits — so you can probe what the agent would see at any moment:
        (describe)
        (fs/write :path "/home/agent/notes.txt" :content "hi")
    """
  end

  # --- banner ---

  defp banner(server) do
    IO.puts("")
    IO.puts(
      Core.paint(35, "substrate operator console") <>
        Core.paint(90, "  —  trusted L2 · \\help for verbs · \\mount to build · \\q to quit")
    )

    IO.puts("")

    case Server.describe(server, nil) do
      "" -> IO.puts(Core.paint(90, "  (empty surface — \\mount a substrate to begin)"))
      surface -> IO.puts(Core.indent(surface))
    end

    IO.puts("")
  end
end
