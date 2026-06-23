defmodule Substrate.HarnessTest do
  @moduledoc """
  Drives the reference L3 harness (`Substrate.Harness`) against a *live*
  substrate, end to end — the same way an integrator's host loop would. Every
  test exercises a real disposition branch through `observe`/`discover`/`pursue`
  and asserts the observable result (including bytes actually on disk).

  The harness only evals. Where a test needs to play the *human*, it does so via
  the `:while_pending` hook — the one seam where the trusted host injects an
  approve/deny verdict out of band. That asymmetry is the design: the agent
  proposes, the host disposes.
  """
  use ExUnit.Case, async: true

  alias Substrate.Harness

  setup do
    root = Path.join(System.tmp_dir!(), "harness_test_#{System.unique_integer([:positive])}")
    File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, "notes"))
    File.write!(Path.join(root, "notes/todo.txt"), "buy milk")
    File.write!(Path.join(root, "notes/ideas.txt"), "an operating system for agents")
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, s} = Substrate.start_link(name: nil)
    manifest = "priv/manifests/fs.lisp" |> File.read!() |> Substrate.read_manifest()
    :ok = Substrate.mount(s, manifest, credentials: %{fs_root: root})
    %{s: s, root: root}
  end

  describe "introspection — the agent discovers the surface" do
    test "discover returns the stripped namespace render", %{s: s} do
      surface = Harness.discover(s)
      assert surface =~ "fs/read"
      assert surface =~ "fs/write"
      refute surface =~ "Substrate.FS"
    end

    test "capabilities/1 parses the live capability list", %{s: s} do
      caps = Harness.capabilities(s)
      assert Enum.sort(caps) == ~w(fs/delete fs/list fs/read fs/write)
    end

    test "the list reflects a live revoke (capabilities are data)", %{s: s} do
      assert "fs/read" in Harness.capabilities(s)
      :ok = Substrate.revoke(s, "fs/read")
      # signature stays on the surface (still listed), just marked revoked —
      # the agent can still SEE it, which is the point of the frozen ABI.
      assert "fs/read" in Harness.capabilities(s)
      assert Harness.discover(s) =~ "revoked"
    end
  end

  describe "observe — every emission normalizes to a flat outcome" do
    test "a happy-path program writes a real file and reports :done", %{s: s, root: root} do
      assert {:done, %{path: "notes/report.txt"}} =
               Harness.observe(s, ~s|(fs/write :path "notes/report.txt" :content "shipped")|)
      assert File.read!(Path.join(root, "notes/report.txt")) == "shipped"
    end

    test "the agent's own bad code surfaces as :fault, not a crash", %{s: s} do
      assert {:fault, msg} = Harness.observe(s, "(totally-made-up :x 1)")
      assert msg =~ "unbound"
    end

    test "a jailbreak attempt comes back :denied", %{s: s} do
      assert {:denied, _} =
               Harness.observe(s, ~s|(fs/read :path "../../../etc/passwd")|)
    end

    test "a whole program — list + per-file read — runs in one emission", %{s: s} do
      program = ~s"""
      (let [listing (fs/list :path "notes")]
        (case listing
          (:done d)   (count (:entries d))
          (:denied e) -1))
      """

      # setup seeds notes/ with todo.txt + ideas.txt
      assert {:value, 2} = Harness.observe(s, program)
    end
  end

  describe "pursue — seeing an intent through to a terminal disposition" do
    test "queued effect: host approves via the hook, harness settles :done", %{s: s, root: root} do
      approver = fn handle -> Substrate.approve(s, handle) end

      assert {:done, %{path: "publish.txt"}} =
               Harness.pursue(s, ~s|(fs/write :path "publish.txt" :content "live")|,
                 while_pending: approver
               )

      assert File.read!(Path.join(root, "publish.txt")) == "live"
    end

    test "queued effect: host denies via the hook, harness settles :denied", %{s: s, root: root} do
      denier = fn handle -> Substrate.deny(s, handle) end

      assert {:denied, %{reason: reason}} =
               Harness.pursue(s, ~s|(fs/write :path "leak.txt" :content "oops")|,
                 while_pending: denier
               )

      assert reason =~ "human"
      refute File.exists?(Path.join(root, "leak.txt"))
    end

    test "unattended harness gives up with :queued when no verdict arrives", %{s: s} do
      # default while_pending is a no-op → patience runs out, still pending
      assert {:queued, %{handle: _}} =
               Harness.pursue(s, ~s|(fs/write :path "orphan.txt" :content "x")|, patience: 2)
    end

    test "an in-jail write needs no human and settles :done immediately", %{s: s} do
      assert {:done, _} =
               Harness.pursue(s, ~s|(fs/write :path "notes/quiet.txt" :content "x")|)
    end
  end

  describe "run — a multi-step goal, reacting to each disposition" do
    test "trace records each outcome and the summary counts them by tag", %{s: s, root: root} do
      # A plan that deliberately hits four different branches:
      steps = [
        {:in_jail, ~s|(fs/write :path "notes/a.txt" :content "1")|},
        {:escape, ~s|(fs/write :path "../../etc/x" :content "2")|},
        {:bad_code, ~s|(frobnicate :x 1)|},
        {:needs_human, ~s|(fs/write :path "outside.txt" :content "3")|}
      ]

      {trace, summary} =
        Harness.run(s, steps, while_pending: fn h -> Substrate.approve(s, h) end)

      assert {:in_jail, {:done, _}} = List.keyfind(trace, :in_jail, 0)
      assert {:escape, {:denied, _}} = List.keyfind(trace, :escape, 0)
      assert {:bad_code, {:fault, _}} = List.keyfind(trace, :bad_code, 0)
      assert {:needs_human, {:done, _}} = List.keyfind(trace, :needs_human, 0)

      # in_jail + (approved) needs_human both ran → 2 :done
      assert summary[:done] == 2
      assert summary[:denied] == 1
      assert summary[:fault] == 1

      # the two approved writes really landed; the escape never did:
      assert File.exists?(Path.join(root, "notes/a.txt"))
      assert File.exists?(Path.join(root, "outside.txt"))
    end

    test "the rate budget is enforced across a run of identical writes", %{s: s} do
      steps = for i <- 1..7, do: {i, ~s|(fs/write :path "notes/r#{i}.txt" :content "x")|}
      {_trace, summary} = Harness.run(s, steps)

      assert summary[:done] == 5
      assert summary[:"rate-limited"] == 2
    end
  end
end
