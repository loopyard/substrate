defmodule Mix.Tasks.Substrate.Console do
  use Mix.Task

  @shortdoc "Operator console for building & debugging a substrate (trusted L2)"
  @moduledoc """
  Drop into the **operator console** — the trusted L2 side of the wall, where you
  *build and debug* a substrate. Contrast `mix substrate.repl`, which is the
  untrusted L3 seam an agent talks to.

  With no files, you start on an **empty surface** and build it up live with
  `\\mount`. With files, they are preloaded first:

      mix substrate.console
      mix substrate.console priv/substrates/roots.lisp
      mix substrate.console priv/substrates/fs_locked.lisp --reveal --cred fs_root=/tmp/sandbox

  Inside, `\\help` lists the verbs: mount, revoke/restore, reveal, the approval
  queue (queue/approve/deny), and audit. Bare input is evaluated through the same
  `Substrate.eval/2` seam the agent hits, so you can probe the surface as the
  agent at any moment.

  Options (applied to any files passed on the command line):
    --reveal            reveal each capability's policy rules in (describe)
    --cred KEY=VALUE    bind an L0 credential (repeatable); a comma-separated
                        VALUE becomes a list, e.g. --cred fs_roots=/home,/tmp
  """

  @impl true
  def run(argv) do
    {opts, paths, _} = OptionParser.parse(argv, strict: [reveal: :boolean, cred: :keep])

    Mix.Task.run("app.start")

    server =
      if paths == [] do
        {:ok, server} = Substrate.start_link([])
        server
      else
        mount_opts = [
          reveal_rules: Keyword.get(opts, :reveal, false),
          credentials: parse_creds(opts)
        ]

        case Substrate.load(paths, mount_opts) do
          {:ok, server} -> server
          other -> Mix.raise("could not load substrate(s): #{inspect(other)}")
        end
      end

    Substrate.Console.loop(server)
  end

  defp parse_creds(opts) do
    opts
    |> Keyword.get_values(:cred)
    |> Map.new(fn kv ->
      case String.split(kv, "=", parts: 2) do
        [k, v] -> {String.to_atom(k), parse_value(v)}
        _ -> Mix.raise("bad --cred #{inspect(kv)} — expected KEY=VALUE")
      end
    end)
  end

  defp parse_value(v), do: if(String.contains?(v, ","), do: String.split(v, ","), else: v)
end
