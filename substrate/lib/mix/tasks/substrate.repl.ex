defmodule Mix.Tasks.Substrate.Repl do
  use Mix.Task

  @shortdoc "Interactive REPL attached to a live substrate"
  @moduledoc """
  Mount one or more substrate files and drop into an interactive console over
  stdio. Everything you type is evaluated through the real untrusted seam
  (`Substrate.eval/2`) — the same wall an agent would hit.

      mix substrate.repl priv/substrates/roots.lisp
      mix substrate.repl priv/substrates/dir.lisp --cred fs_root=/tmp/sandbox
      mix substrate.repl priv/substrates/fs_locked.lisp priv/substrates/http.lisp --reveal

  Options:
    --reveal            reveal each capability's policy rules in (describe)
    --cred KEY=VALUE    bind an L0 credential (repeatable); a comma-separated
                        VALUE becomes a list, e.g. --cred fs_roots=/home,/tmp
  """

  @impl true
  def run(argv) do
    {opts, paths, _} = OptionParser.parse(argv, strict: [reveal: :boolean, cred: :keep])

    if paths == [] do
      Mix.raise("usage: mix substrate.repl <substrate.lisp> [more.lisp ...] [--reveal] [--cred k=v]")
    end

    Mix.Task.run("app.start")

    mount_opts = [
      reveal_rules: Keyword.get(opts, :reveal, false),
      credentials: parse_creds(opts)
    ]

    case Substrate.load(paths, mount_opts) do
      {:ok, server} -> Substrate.Repl.loop(server)
      other -> Mix.raise("could not load substrate(s): #{inspect(other)}")
    end
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
