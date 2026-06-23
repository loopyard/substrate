defmodule Substrate.AgentTest do
  @moduledoc """
  Drives the LLM agent loop (`Substrate.Agent`) against a *live* substrate with a
  **canned model** — a stub fun that returns scripted assistant turns — so the
  whole react-to-disposition loop runs end to end with no network. The point is
  the wiring: programs are evaluated through the real L3 seam, dispositions feed
  back as the next turn, and a fault is data the agent recovers from rather than
  a crash. The real Claude driver (`Substrate.Agent.Anthropic`) is the same loop
  with a different model fun.
  """
  use ExUnit.Case, async: true

  alias Substrate.Agent

  # A stub model: replies with `responses[n]` where n = assistant turns so far.
  defp canned(responses) do
    fn _system, messages ->
      n = Enum.count(messages, &(&1.role == "assistant"))
      {:ok, Enum.at(responses, n) || "DONE (ran out of script)"}
    end
  end

  defp lisp(program), do: "Here goes.\n```lisp\n#{program}\n```"

  setup do
    root = Path.join(System.tmp_dir!(), "agent_test_#{System.unique_integer([:positive])}")
    File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, "notes"))
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, server} = Substrate.start_link(name: nil)
    ast = "priv/substrates/fs.lisp" |> File.read!() |> Substrate.read_substrate()
    :ok = Substrate.mount(server, ast, credentials: %{fs_root: root})
    %{server: server, root: root}
  end

  test "agent writes then reads through the seam and finishes with DONE", %{server: server, root: root} do
    model =
      canned([
        lisp(~s|(fs/write :path "notes/hello.txt" :content "hi from the agent")|),
        lisp(~s|(fs/read :path "notes/hello.txt")|),
        "DONE wrote the note and read it back"
      ])

    {:ok, run} = Agent.run(server, "write and read a note", model)

    assert run.outcome == :solved
    assert run.summary =~ "read it back"
    # two emissions (the DONE turn is not a program step)
    assert length(run.steps) == 2
    assert {:done, _} = Enum.at(run.steps, 0).outcome
    assert {:done, payload} = Enum.at(run.steps, 1).outcome
    assert payload.content == "hi from the agent"
    # and the bytes really landed on disk via the native edge
    assert File.read!(Path.join(root, "notes/hello.txt")) == "hi from the agent"
  end

  test "a fault is fed back and the agent recovers on the next turn", %{server: server} do
    model =
      canned([
        lisp("(fs/frobnicate :path \"notes/x.txt\")"),
        lisp(~s|(fs/write :path "notes/x.txt" :content "ok")|),
        "DONE recovered after the fault"
      ])

    {:ok, run} = Agent.run(server, "do a thing", model)

    assert run.outcome == :solved
    assert {:fault, msg} = Enum.at(run.steps, 0).outcome
    assert msg =~ "frobnicate" or msg =~ "unbound"
    assert {:done, _} = Enum.at(run.steps, 1).outcome
  end

  test "a denied effect is surfaced as a disposition, not a crash", %{server: server} do
    # writing outside the jail is refused by the membrane (deny-if escapes-jail)
    model =
      canned([
        lisp(~s|(fs/write :path "../escape.txt" :content "nope")|),
        "DONE the membrane refused, as expected"
      ])

    {:ok, run} = Agent.run(server, "try to escape", model)
    assert run.outcome == :solved
    assert {:denied, _} = Enum.at(run.steps, 0).outcome
  end

  test "the step budget bounds a model that never finishes", %{server: server} do
    forever = fn _s, _m -> {:ok, lisp("(describe)")} end
    {:ok, run} = Agent.run(server, "loop forever", forever, max_steps: 3)

    assert run.outcome == :exhausted
    assert length(run.steps) == 3
  end

  test "events stream in order to the on_event hook", %{server: server} do
    model = canned([lisp("(describe)"), "DONE looked around"])
    me = self()

    {:ok, _run} = Agent.run(server, "look", model, on_event: fn ev -> send(me, {:ev, ev}) end)

    assert_received {:ev, {:think, _}}
    assert_received {:ev, {:act, "(describe)"}}
    assert_received {:ev, {:result, {:text, _}}}
    assert_received {:ev, {:done, "looked around"}}
  end

  describe "parsing" do
    test "extract_program pulls the first fenced block" do
      assert Agent.extract_program("text\n```lisp\n(describe)\n```\nmore") == "(describe)"
      assert Agent.extract_program("```\n(fs/read :path \"x\")\n```") == ~s|(fs/read :path "x")|
    end

    test "extract_program returns nil with no fence" do
      assert Agent.extract_program("just prose, no code") == nil
      assert Agent.extract_program("```lisp\n\n```") == nil
    end

    test "done_summary detects a DONE line" do
      assert Agent.done_summary("DONE: all set") == "all set"
      assert Agent.done_summary("blah\ndone finished up") == "finished up"
      assert Agent.done_summary("DONE") == "done"
      assert Agent.done_summary("not done yet, still working") == nil
    end
  end

  describe "render" do
    test "each disposition renders to a line the model can read" do
      assert Agent.render({:done, %{bytes: 2}}) =~ "done"
      assert Agent.render({:queued, %{handle: "eff_1"}}) =~ "eff_1"
      assert Agent.render({:denied, %{reason: "capability suspended"}}) =~ "suspended"
      assert Agent.render({:fault, "unbound: foo"}) =~ "fault"
      assert Agent.render({:text, "the surface"}) == "the surface"
    end
  end
end
