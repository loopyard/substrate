defmodule Mix.Tasks.Substrate.Agent do
  use Mix.Task

  @shortdoc "Run an LLM agent over a loaded substrate"
  @moduledoc """
  Load one or more substrate files and turn an LLM loose on them toward a goal.
  The model sits at the untrusted L3 seam — it reads the surface, emits
  substrate-Lisp, and reacts to each disposition — exactly where a human sits in
  `mix substrate.repl`, but autonomous.

      ANTHROPIC_API_KEY=sk-ant-... \\
        mix substrate.agent priv/substrates/roots.lisp \\
          --goal "Write a short note to /home/agent/hello.txt, then read it back."

      mix substrate.agent priv/substrates/fs.lisp --cred fs_root=/tmp/sandbox \\
        --goal "List the notes directory and summarise what's there."

  Options:
    --goal TEXT         the task for the agent (required)
    --model ID          Claude model id (default claude-opus-4-8)
    --max-steps N       emission budget before giving up (default 12)
    --max-tokens N      per-response token cap (default 4096)
    --reveal            reveal capability policy rules in (describe)
    --cred KEY=VALUE    bind an L0 credential (repeatable)
  """

  alias Substrate.Agent

  @impl true
  def run(argv) do
    {opts, paths, _} =
      OptionParser.parse(argv,
        strict: [goal: :string, model: :string, max_steps: :integer, max_tokens: :integer, reveal: :boolean, cred: :keep]
      )

    goal = Keyword.get(opts, :goal) || Mix.raise("--goal is required")
    if paths == [], do: Mix.raise("usage: mix substrate.agent <substrate.lisp> [...] --goal \"...\"")

    Mix.Task.run("app.start")

    mount_opts = [reveal_rules: Keyword.get(opts, :reveal, false), credentials: parse_creds(opts)]
    {:ok, server} = Substrate.load(paths, mount_opts)

    model =
      Substrate.Agent.Anthropic.model(
        model: Keyword.get(opts, :model, "claude-opus-4-8"),
        max_tokens: Keyword.get(opts, :max_tokens, 4096)
      )

    run_opts = [max_steps: Keyword.get(opts, :max_steps, 12), on_event: &narrate/1]

    banner(goal)

    case Agent.run(server, goal, model, run_opts) do
      {:ok, run} -> report(server, run)
      {:error, reason} -> Mix.raise("agent error: #{reason}")
    end
  end

  # --- live narration of the loop ---

  defp narrate({:think, text}), do: IO.puts(paint(90, indent(String.trim(text))))
  defp narrate({:act, program}), do: IO.puts(paint(36, "  ▸ " <> one_line(program)))
  defp narrate({:result, outcome}), do: IO.puts(paint(33, "    ⤷ " <> Agent.render(outcome)))
  defp narrate({:nudge, _msg}), do: IO.puts(paint(31, "    (no program emitted — nudging)"))
  defp narrate({:done, summary}), do: IO.puts(paint(32, "\n  ✓ " <> summary))
  defp narrate({:error, reason}), do: IO.puts(paint(31, "  x " <> to_string(reason)))

  # --- final report ---

  defp report(server, run) do
    IO.puts("")
    IO.puts(paint(1, "outcome: #{run.outcome}") <> "  (#{length(run.steps)} emissions)")
    IO.puts("  #{run.summary}")
    IO.puts("")
    IO.puts(paint(90, "audit (trusted side):"))

    case Substrate.audit(server) do
      [] -> IO.puts("  (no calls adjudicated)")
      entries -> Enum.each(entries, fn %{seq: n, cap: cap, outcome: out} -> IO.puts("  ##{n}  #{cap}  ->  #{inspect(out)}") end)
    end
  end

  defp banner(goal) do
    IO.puts("")
    IO.puts(paint(35, "substrate agent") <> paint(90, "  —  an LLM at the L3 seam"))
    IO.puts(paint(90, "goal: ") <> goal)
    IO.puts("")
  end

  # --- helpers ---

  defp parse_creds(opts) do
    opts
    |> Keyword.get_values(:cred)
    |> Map.new(fn kv ->
      case String.split(kv, "=", parts: 2) do
        [k, v] -> {String.to_atom(k), if(String.contains?(v, ","), do: String.split(v, ","), else: v)}
        _ -> Mix.raise("bad --cred #{inspect(kv)} — expected KEY=VALUE")
      end
    end)
  end

  defp one_line(program), do: program |> String.split("\n") |> Enum.map_join(" ", &String.trim/1)
  defp indent(text), do: text |> String.split("\n") |> Enum.map_join("\n", &("  " <> &1))
  defp paint(code, text), do: "\e[#{code}m#{text}\e[0m"
end
