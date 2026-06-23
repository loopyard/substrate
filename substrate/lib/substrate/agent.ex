defmodule Substrate.Agent do
  @moduledoc """
  An **LLM agent loop** that drives a live substrate — the CodeAct move from
  `DESIGN.md` made real. Where `mix substrate.repl` puts a *human* at the L3
  seam, this puts a *model* there: it reads the surface, emits a substrate-Lisp
  program, and reacts to the disposition that comes back — turn after turn, until
  the goal is met or a step budget runs out.

  Like `Substrate.Harness`, this code is **untrusted L3**: it touches only
  `Substrate.eval/2` (via `Harness.observe/2`). It never names a credential,
  never approves its own effects. The wall the model hits here is the real one.

  The `model` is injected — a 2-arity fun `(system, messages) -> {:ok, text} |
  {:error, reason}`, where `messages` is a list of `%{role: "user"|"assistant",
  content: binary}`. `Substrate.Agent.Anthropic.model/1` is the real Claude
  driver; tests pass a canned fun, so the whole loop runs with no network.

  ## Protocol

  The system prompt tells the model to emit exactly one program per turn inside a
  ```` ```lisp ```` fence; the loop runs it through the seam and feeds the
  rendered disposition back as the next user message. To finish, the model
  replies with a line beginning `DONE` (and no code block).

  Returns `{:ok, %{outcome: :solved | :exhausted | :stuck, summary: binary,
  steps: [step], transcript: messages}}`. Each `step` is
  `%{program: binary, outcome: Harness.outcome}` (a nudge step carries
  `program: nil`).
  """

  alias Substrate.{Harness, Server, Show}

  @default_max_steps 12

  @doc """
  Run the agent loop against a live `server` toward `goal`, using `model`.

  Options:

    * `:max_steps`  — emission budget before giving up (default #{@default_max_steps})
    * `:on_event`   — a 1-arity fun called with progress events as they happen:
      `{:think, text}`, `{:act, program}`, `{:result, outcome}`,
      `{:done, summary}`, `{:nudge, message}`, `{:error, reason}`. Default: no-op.
  """
  def run(server, goal, model, opts \\ []) do
    max_steps = Keyword.get(opts, :max_steps, @default_max_steps)
    on_event = Keyword.get(opts, :on_event, fn _ -> :ok end)

    system = system_prompt()
    first = first_message(server, goal)
    loop([%{role: "user", content: first}], server, model, on_event, max_steps, [], system)
  end

  # --- the loop ---

  defp loop(messages, _server, _model, on_event, 0, steps, _system) do
    on_event.({:done, "step budget exhausted"})
    {:ok, result(:exhausted, "step budget exhausted before the goal was met", steps, messages)}
  end

  defp loop(messages, server, model, on_event, budget, steps, system) do
    case model.(system, messages) do
      {:ok, text} ->
        on_event.({:think, text})
        messages = messages ++ [%{role: "assistant", content: text}]
        decide(text, messages, server, model, on_event, budget, steps, system)

      {:error, reason} ->
        on_event.({:error, reason})
        {:error, reason}
    end
  end

  # action takes priority over a DONE marker — if there's a program, run it
  defp decide(text, messages, server, model, on_event, budget, steps, system) do
    cond do
      program = extract_program(text) ->
        on_event.({:act, program})
        outcome = Harness.observe(server, program)
        on_event.({:result, outcome})
        step = %{program: program, outcome: outcome}
        feedback = %{role: "user", content: "Result: " <> render(outcome)}
        loop(messages ++ [feedback], server, model, on_event, budget - 1, steps ++ [step], system)

      summary = done_summary(text) ->
        on_event.({:done, summary})
        {:ok, result(:solved, summary, steps, messages)}

      true ->
        msg = "No program found. Emit one substrate-Lisp program in a ```lisp fence, or reply with a line starting DONE and a one-line summary."
        on_event.({:nudge, msg})
        nudge = %{role: "user", content: msg}
        step = %{program: nil, outcome: {:nudge, msg}}

        if budget <= 1 do
          {:ok, result(:stuck, "agent stopped emitting programs", steps ++ [step], messages)}
        else
          loop(messages ++ [nudge], server, model, on_event, budget - 1, steps ++ [step], system)
        end
    end
  end

  defp result(outcome, summary, steps, transcript),
    do: %{outcome: outcome, summary: summary, steps: steps, transcript: transcript}

  # --- parsing the model's text ---

  @fence ~r/```(?:lisp|scheme|clojure)?\s*\n(.*?)```/s

  @doc false
  def extract_program(text) do
    case Regex.run(@fence, text, capture: :all_but_first) do
      [code] ->
        case String.trim(code) do
          "" -> nil
          program -> program
        end

      _ ->
        nil
    end
  end

  @doc false
  def done_summary(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      case Regex.run(~r/^\s*DONE[:\s-]*(.*)$/i, line, capture: :all_but_first) do
        [rest] -> if(String.trim(rest) == "", do: "done", else: String.trim(rest))
        _ -> nil
      end
    end)
  end

  # --- rendering a disposition back to the model ---

  @doc false
  def render({:done, payload}), do: "done — " <> Show.form(payload)
  def render({:queued, %{handle: h}}), do: "queued for human review (handle #{inspect(h)}) — re-check with (await \"#{h}\")"
  def render({:queued, payload}), do: "queued — " <> Show.form(payload)
  def render({:"rate-limited", payload}), do: "rate-limited — " <> Show.form(payload)
  def render({:denied, %{reason: r}}), do: "denied — #{r}"
  def render({:denied, payload}), do: "denied — " <> Show.form(payload)
  def render({:fault, msg}), do: "fault (your program was bad) — #{msg}"
  def render({:text, str}), do: str
  def render({:value, term}), do: Show.form(term)
  def render(other), do: inspect(other)

  # --- prompts ---

  defp first_message(server, goal) do
    """
    Goal: #{goal}

    You are attached to a substrate. Here is its current surface:

    #{Server.describe(server, nil)}

    Emit your first program.
    """
  end

  defp system_prompt do
    """
    You operate a *substrate*: a sandboxed machine whose only I/O is a set of
    capabilities. You act by writing small programs in substrate-Lisp; each
    program is evaluated and you get back a DISPOSITION, not a value:

      done          the effect ran (a result map is attached)
      queued        held for a human; re-check with (await "<handle>")
      rate-limited  budget spent; a :retry_after is attached
      denied        the membrane refused (a reason is attached)
      fault         YOUR program was bad (unbound symbol, bad call) — fix and retry

    The language is a small Lisp — a real computer, not a menu:

      forms     (do ...) (let [x 1] ...) (if c a b) (cond (t v)...) (case v ...)
                (fn [x] ...) (defn f [x] ...) recursion works, incl. mutual
                (and ..) (or ..) (def x v) (quote f) (grant ...) (as child ...)
      math      + - * / quot rem mod inc dec abs min max  < > <= >= =  not
      seqs      list count first rest nth reverse sort cons conj concat range
                map filter reduce contains?
      maps      get assoc keys vals    strings: str join split upcase downcase
                                                 starts-with? ends-with?
      json      parse-json (-> string-keyed map) to-json    truth: all but false/nil

    Capabilities are namespaced `ns/name` (e.g. fs/read). Builtins are bare,
    but also reachable namespaced (collection/reduce, string/split, math/mod) — handy if
    you define your own `reduce`: the bare name is yours, collection/reduce is the builtin.
    Build a result map key with a string, read it with (get m "key"); keyword
    accessors like (:body r) read dispositions and known keys.

    Rules of engagement:

    - Emit EXACTLY ONE program per turn, inside a ```lisp fenced code block.
    - Introspect before you act: `(describe)` lists the surface, `(describe cap)`
      details one capability (its params, return shape, and example).
    - You can only call capabilities that appear on the surface. Inventing one is
      a fault. If you fault, re-read the surface and correct your program.
    - React to the disposition. A `denied` or `queued` is information, not a wall
      to bang on — adapt. Don't retry an identical denied call.
    - Keep a brief line of reasoning before the code block if it helps.
    - When the goal is met (or genuinely cannot be), reply with a single line
      that begins with DONE followed by a one-line summary, and NO code block.
    """
  end
end
