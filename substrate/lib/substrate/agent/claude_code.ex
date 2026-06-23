defmodule Substrate.Agent.ClaudeCode do
  @moduledoc """
  A model driver for `Substrate.Agent` that puts **Claude Code itself** at the
  L3 seam — by shelling out to the `claude -p` CLI rather than calling the
  Messages API directly. Where `Substrate.Agent.Anthropic` needs an
  `ANTHROPIC_API_KEY`, this one rides whatever auth the local `claude` binary
  already has (a logged-in Claude Code, or its own key), so the substrate can be
  driven with no key in the environment and still no external Elixir deps.

  `model/1` returns the same 2-arity fun the loop expects
  (`(system, messages) -> {:ok, text} | {:error, reason}`).

  ## Keeping Claude *at the seam*

  The whole point of the substrate is that the model acts **only** through the
  capability wall — it emits substrate-Lisp and reacts to dispositions. A naive
  `claude -p` would happily use its *own* `Bash`/`Read`/`Write` tools and just do
  the task directly, walking straight around the wall under test. So we invoke it
  with `--tools ""` (every built-in tool disabled): Claude becomes a pure text
  model whose only way to affect the world is the Lisp it writes into the seam.

  ## Statelessness

  The loop re-sends the full message list every turn (exactly like the API
  driver), so we don't thread a `claude` session id. Instead each call renders
  the running transcript into one prompt — prior assistant turns become context —
  and Claude's reply is a fresh single-shot completion. The system prompt and the
  transcript are passed via temp files (`--system-prompt-file` and stdin) so
  arbitrarily long, model-authored content never has to survive argv limits or
  shell quoting.

  Config (all overridable via `opts`):

    * `:bin`   — the CLI to invoke (default `"claude"`)
    * `:model` — a `claude` model id/alias passed through with `--model`
      (default: let the CLI choose); validated to a safe charset since it lands
      in the command line
    * `:timeout` — per-turn wall-clock budget in ms (default 120_000)
  """

  alias Substrate.JSON

  @default_bin "claude"
  @default_timeout 120_000
  @model_id ~r/^[A-Za-z0-9._:\-]+$/

  @doc """
  Build the model fun for `Substrate.Agent.run/4`.

  Does not check that `claude` is logged in — that surfaces as an `{:error, _}`
  disposition on the first turn (the loop's normal error path), not a crash at
  construction time. Use `available?/1` for a friendly pre-flight.
  """
  def model(opts \\ []) do
    bin = Keyword.get(opts, :bin, @default_bin)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    model_id = validate_model(Keyword.get(opts, :model))

    fn system, messages -> chat(bin, model_id, timeout, system, messages) end
  end

  @doc """
  Pre-flight: is the `claude` binary present and logged in? Returns `:ok` or
  `{:error, reason}` with a human-actionable message. Costs one tiny `claude -p`
  round-trip.
  """
  def available?(opts \\ []) do
    bin = Keyword.get(opts, :bin, @default_bin)

    case System.find_executable(bin) do
      nil ->
        {:error, "`#{bin}` is not on PATH — install Claude Code or pass --bin"}

      _path ->
        # A trivial prompt; an unauthenticated CLI answers with is_error + a
        # "Please run /login" result rather than failing the process.
        case chat(bin, nil, 20_000, "Reply with exactly: OK", [
               %{role: "user", content: "ping"}
             ]) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # --- the call ---

  defp chat(bin, model_id, timeout, system, messages) do
    prompt = render_prompt(messages)

    with {:ok, sys_file} <- write_temp("sys", system),
         {:ok, prompt_file} <- write_temp("prompt", prompt) do
      try do
        run_cli(bin, model_id, timeout, sys_file, prompt_file)
      after
        File.rm(sys_file)
        File.rm(prompt_file)
      end
    end
  end

  defp run_cli(bin, model_id, timeout, sys_file, prompt_file) do
    model_flag = if model_id, do: " --model #{model_id}", else: ""

    # `--tools ''` disables every built-in tool; the transcript arrives on stdin
    # and the system prompt via file. bin/model_id are validated; the file paths
    # are our own mktemp names — nothing model-authored touches the shell line.
    command =
      "#{bin} -p --output-format json --tools '' " <>
        "--system-prompt-file #{sys_file}#{model_flag} < #{prompt_file}"

    task = Task.async(fn -> System.cmd("sh", ["-c", command], stderr_to_stdout: true) end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {out, status}} -> interpret(out, status)
      nil -> {:error, "claude timed out after #{timeout}ms"}
    end
  end

  # The CLI emits its result JSON on both success and failure (e.g. an
  # unauthenticated run exits non-zero but still reports "Not logged in" in the
  # JSON). So always try to parse first — that yields the clean reason — and only
  # fall back to exit-code framing when the output wasn't usable JSON at all.
  defp interpret(out, status) do
    case parse_response(out) do
      {:error, "could not parse" <> _} when status != 0 ->
        {:error, "claude exited #{status}: #{snippet(out)}"}

      result ->
        result
    end
  end

  # --- pure helpers (unit-tested with no CLI) ---

  @doc """
  Render the running message list into a single prompt. Prior assistant turns
  become labelled context; a closing instruction reasserts the one-program turn
  contract so the single-shot completion behaves like the next loop step.
  """
  def render_prompt(messages) do
    body =
      Enum.map_join(messages, "\n\n", fn
        %{role: "user", content: c} -> "## OPERATOR\n#{c}"
        %{role: "assistant", content: c} -> "## YOU (earlier turn)\n#{c}"
      end)

    body <>
      "\n\n## YOUR TURN\n" <>
      "Continue from the transcript above. Emit exactly one ```lisp program for " <>
      "your next move, or a single line starting with DONE if the goal is met."
  end

  @doc """
  Pull the assistant text out of a `claude -p --output-format json` result.

  An unauthenticated or errored CLI still exits 0 but sets `is_error: true` with
  the reason in `result` (e.g. "Not logged in"), so we surface that as an error
  the loop can report rather than feeding "Please run /login" back as a turn.
  """
  def parse_response(out) do
    case JSON.decode(out) do
      {:ok, %{"is_error" => true} = r} ->
        {:error, "claude: #{r["result"] || inspect(r)}"}

      {:ok, %{"result" => text}} when is_binary(text) ->
        {:ok, text}

      {:ok, other} ->
        {:error, "unexpected claude json (no result field): #{snippet(inspect(other))}"}

      {:error, reason} ->
        {:error, "could not parse claude output: #{reason} — raw: #{snippet(out)}"}
    end
  end

  # --- internals ---

  defp validate_model(nil), do: nil

  defp validate_model(id) when is_binary(id) do
    if Regex.match?(@model_id, id),
      do: id,
      else: raise(ArgumentError, "unsafe --model #{inspect(id)} (allowed: #{inspect(@model_id.source)})")
  end

  defp write_temp(tag, contents) do
    path =
      Path.join(
        System.tmp_dir!(),
        "substrate_agent_#{tag}_#{System.unique_integer([:positive])}.txt"
      )

    case File.write(path, contents) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, "could not stage #{tag} file: #{:file.format_error(reason)}"}
    end
  end

  defp snippet(s) when is_binary(s), do: s |> String.trim() |> String.slice(0, 400)
  defp snippet(other), do: other |> inspect() |> String.slice(0, 400)
end
