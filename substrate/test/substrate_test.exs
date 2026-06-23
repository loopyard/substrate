defmodule SubstrateTest do
  @moduledoc """
  Drives a live substrate through the public seam and asserts the *structural*
  guarantees — the wall, the jail, and the disposition contract — are real, not
  rendered. The demos narrate these; here they're pinned as raw Elixir terms.
  """
  use ExUnit.Case, async: true

  setup do
    root = Path.join(System.tmp_dir!(), "substrate_test_#{System.unique_integer([:positive])}")
    File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, "notes"))
    File.write!(Path.join(root, "notes/todo.txt"), "buy milk")
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, s} = Substrate.start_link(name: nil)
    substrate = "priv/substrates/fs.lisp" |> File.read!() |> Substrate.read_substrate()
    :ok = Substrate.mount(s, substrate, credentials: %{fs_root: root})
    %{s: s, root: root}
  end

  describe "the capability wall — zero ambient authority" do
    test "ambient host operations have no referent (unbound, not denied)", %{s: s} do
      assert {:fault, msg} = Substrate.eval(s, ~s|(read-file "/etc/passwd")|)
      assert msg =~ "unbound symbol"

      assert {:fault, msg2} = Substrate.eval(s, ~s|(System/getenv "HOME")|)
      assert msg2 =~ "unbound symbol"
    end

    test "the jail root is never a value the agent can name", %{s: s} do
      assert {:fault, msg} = Substrate.eval(s, "(fs/root)")
      assert msg =~ "unbound symbol"
    end

    test "describe strips the native binding and concrete predicates", %{s: s} do
      surface = Substrate.eval(s, "(describe fs/write)")
      assert is_binary(surface)
      assert surface =~ "fs/write"
      # mechanism and authority are not on the surface:
      refute surface =~ "bind"
      refute surface =~ "Substrate.FS"
      refute surface =~ "outside-safe"
      # but the honest abstracted policy is:
      assert surface =~ "confirm-if"
    end
  end

  describe "dispositions — every call returns one, never a raw effect" do
    test "a read inside the jail is :done with the payload", %{s: s} do
      assert {:disposition, :done, %{content: "buy milk", bytes: 8}} =
               Substrate.eval(s, ~s|(fs/read :path "notes/todo.txt")|)
    end

    test "a path escaping the jail is :denied by deny-if", %{s: s} do
      assert {:disposition, :denied, %{reason: reason}} =
               Substrate.eval(s, ~s|(fs/read :path "../../../etc/passwd")|)
      assert reason =~ "policy"
    end

    test "a write inside the safe area really hits disk", %{s: s, root: root} do
      assert {:disposition, :done, %{bytes: 5, path: "notes/new.txt"}} =
               Substrate.eval(s, ~s|(fs/write :path "notes/new.txt" :content "hello")|)
      assert File.read!(Path.join(root, "notes/new.txt")) == "hello"
    end

    test "a write outside the safe area is :queued, not executed", %{s: s, root: root} do
      assert {:disposition, :queued, %{handle: "eff_1"}} =
               Substrate.eval(s, ~s|(fs/write :path "loose.txt" :content "x")|)
      # nothing on disk until a human approves:
      refute File.exists?(Path.join(root, "loose.txt"))
    end
  end

  describe "the human queue — approve/deny resolve a parked effect" do
    test "approve runs the effect and await reports :done", %{s: s, root: root} do
      assert {:disposition, :queued, %{handle: handle}} =
               Substrate.eval(s, ~s|(fs/write :path "approved.txt" :content "ok")|)

      assert {:disposition, :done, _} = Substrate.approve(s, handle)
      assert {:disposition, :done, %{path: "approved.txt"}} =
               Substrate.eval(s, ~s|(await "#{handle}")|)
      assert File.read!(Path.join(root, "approved.txt")) == "ok"
    end

    test "deny rejects it and await reports :denied", %{s: s, root: root} do
      assert {:disposition, :queued, %{handle: handle}} =
               Substrate.eval(s, ~s|(fs/write :path "rejected.txt" :content "no")|)

      assert {:disposition, :denied, _} = Substrate.deny(s, handle)
      assert {:disposition, :denied, %{reason: reason}} =
               Substrate.eval(s, ~s|(await "#{handle}")|)
      assert reason =~ "human"
      refute File.exists?(Path.join(root, "rejected.txt"))
    end
  end

  describe "rate-limit — same call, errno flips when the budget is spent" do
    test "the 6th write in the window is :rate-limited", %{s: s} do
      results =
        for i <- 1..6 do
          Substrate.eval(s, ~s|(fs/write :path "notes/n#{i}.txt" :content "x")|)
        end

      tags = Enum.map(results, fn {:disposition, tag, _} -> tag end)
      assert Enum.take(tags, 5) == List.duplicate(:done, 5)
      assert List.last(tags) == :"rate-limited"

      {:disposition, :"rate-limited", payload} = List.last(results)
      assert is_integer(payload.retry_after)
    end
  end

  describe "live surface — revoke keeps the ABI, flips the errno" do
    test "revoke makes the call :denied but the signature stays", %{s: s} do
      assert {:disposition, :done, _} =
               Substrate.eval(s, ~s|(fs/read :path "notes/todo.txt")|)

      :ok = Substrate.revoke(s, "fs/read")

      assert {:disposition, :denied, %{reason: reason}} =
               Substrate.eval(s, ~s|(fs/read :path "notes/todo.txt")|)
      assert reason =~ "suspended"

      # the signature did not vanish — it's still on the surface, marked revoked:
      surface = Substrate.eval(s, "(describe fs)")
      assert surface =~ "fs/read"
      assert surface =~ "revoked"

      :ok = Substrate.restore(s, "fs/read")
      assert {:disposition, :done, _} =
               Substrate.eval(s, ~s|(fs/read :path "notes/todo.txt")|)
    end
  end
end
