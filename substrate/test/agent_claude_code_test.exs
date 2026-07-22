defmodule Substrate.Agent.ClaudeCodeTest do
  @moduledoc """
  Unit-tests the *pure* surface of the `claude -p` driver — prompt rendering and
  response parsing — with no CLI invocation, so the suite stays network-free. The
  shell-out itself (`model/1`, `available?/1`) is exercised live only when a
  logged-in `claude` is present, which CI doesn't assume.
  """
  use ExUnit.Case, async: true

  alias Substrate.Agent
  alias Substrate.Agent.ClaudeCode

  describe "render_prompt/1" do
    test "labels operator and prior-assistant turns and reasserts the contract" do
      messages = [
        %{role: "user", content: "Goal: write a note"},
        %{role: "assistant", content: "```lisp\n(describe)\n```"},
        %{role: "user", content: "Result: the surface"}
      ]

      prompt = ClaudeCode.render_prompt(messages)

      assert prompt =~ "## OPERATOR\nGoal: write a note"
      assert prompt =~ "## YOU (earlier turn)\n```lisp\n(describe)\n```"
      assert prompt =~ "## OPERATOR\nResult: the surface"
      # the closing instruction re-pins the one-program-per-turn protocol
      assert prompt =~ "## YOUR TURN"
      assert prompt =~ "exactly one ```lisp program"
      assert prompt =~ "DONE"
    end

    test "a first turn with only the operator message still frames a turn" do
      prompt = ClaudeCode.render_prompt([%{role: "user", content: "Goal: x"}])
      assert prompt =~ "## OPERATOR\nGoal: x"
      assert prompt =~ "## YOUR TURN"
    end
  end

  describe "parse_response/1" do
    test "pulls the assistant text from a successful result" do
      json = ~s|{"type":"result","is_error":false,"result":"```lisp\\n(describe)\\n```"}|
      assert {:ok, text} = ClaudeCode.parse_response(json)
      assert text == "```lisp\n(describe)\n```"
    end

    test "surfaces an unauthenticated CLI as an error, not a turn" do
      json = ~s|{"type":"result","is_error":true,"result":"Not logged in · Please run /login"}|
      assert {:error, reason} = ClaudeCode.parse_response(json)
      assert reason =~ "Not logged in"
    end

    test "reports unparseable output rather than crashing" do
      assert {:error, reason} = ClaudeCode.parse_response("not json at all")
      assert reason =~ "could not parse"
    end

    test "reports a json result that lacks a result field" do
      assert {:error, reason} = ClaudeCode.parse_response(~s|{"type":"system"}|)
      assert reason =~ "no result field"
    end
  end

  describe "live shell-out through a stub `claude`" do
    setup do
      # A live fs substrate, exactly as the canned-model agent test mounts it.
      root = Path.join(System.tmp_dir!(), "cc_agent_test_#{System.unique_integer([:positive])}")
      File.rm_rf!(root)
      File.mkdir_p!(Path.join(root, "notes"))
      on_exit(fn -> File.rm_rf!(root) end)

      {:ok, server} = Substrate.start_link(name: nil)
      ast = "priv/substrates/fs.lisp" |> File.read!() |> Substrate.read_substrate()
      :ok = Substrate.mount(server, ast, credentials: %{fs_root: root})
      %{server: server, root: root, stub: write_stub()}
    end

    test "runs the real loop over a real OS process at the seam", ctx do
      # Same scenario as the canned-model test, but the model is a *binary*: the
      # driver renders the transcript, spawns the stub via `sh -c ... < tmpfile`
      # with `--tools ''`, and parses its JSON reply — the whole shell-out path,
      # no network, no auth.
      model = ClaudeCode.model(bin: ctx.stub)

      {:ok, run} = Agent.run(ctx.server, "write and read a note", model)

      assert run.outcome == :solved
      assert run.summary =~ "read it back"
      assert length(run.steps) == 2
      assert {:done, _} = Enum.at(run.steps, 0).outcome
      assert {:done, payload} = Enum.at(run.steps, 1).outcome
      assert payload.content == "hello from the stub"
      # the bytes really landed on disk via the native edge
      assert File.read!(Path.join(ctx.root, "notes/hi.txt")) == "hello from the stub"
    end
  end

  # A fake `claude` CLI: reads the transcript on stdin, counts prior assistant
  # turns by our render label, and emits the n-th scripted reply as result JSON —
  # the same "reply with responses[n]" trick the canned model uses, but as a
  # standalone executable so the driver's process plumbing is what's under test.
  defp write_stub do
    path = Path.join(System.tmp_dir!(), "stub_claude_#{System.unique_integer([:positive])}")

    script = ~S"""
    #!/bin/sh
    input=$(cat)
    n=$(printf '%s' "$input" | grep -c '## YOU (earlier turn)')
    case "$n" in
      0) result='```lisp\n(fs/write :path \"notes/hi.txt\" :content \"hello from the stub\")\n```' ;;
      1) result='```lisp\n(fs/read :path \"notes/hi.txt\")\n```' ;;
      *) result='DONE wrote the note and read it back' ;;
    esac
    printf '{"type":"result","is_error":false,"result":"%s"}\n' "$result"
    """

    File.write!(path, script)
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "model/1 validation" do
    test "rejects a model id that could inject into the command line" do
      assert_raise ArgumentError, ~r/unsafe --model/, fn ->
        ClaudeCode.model(model: "foo; rm -rf /")
      end
    end

    test "accepts a normal model id and returns a 2-arity fun" do
      fun = ClaudeCode.model(model: "claude-opus-4-8")
      assert is_function(fun, 2)
    end
  end
end
