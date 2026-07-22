defmodule Substrate.NamespacingTest do
  @moduledoc """
  Name conflicts are inevitable, so resolution is built in, not bolted on:
  the stdlib is reachable namespaced (`collection/reduce`) as well as bare, so a user
  `defn` can shadow a bare name without losing the builtin; and mounting refuses
  to silently clobber a capability, offering `as:` to rename a namespace.
  """
  use ExUnit.Case, async: true

  alias Substrate.Lisp.Stdlib

  defp fresh, do: elem(Substrate.start_link(name: nil), 1)
  defp eval(s, src), do: Substrate.eval(s, src)
  defp fs, do: "priv/substrates/fs.lisp" |> File.read!() |> Substrate.read_substrate()

  describe "stdlib namespaces" do
    test "every builtin is reachable bare and as ns/name" do
      s = fresh()
      assert 10 = eval(s, "(reduce (fn [a x] (+ a x)) 0 (range 5))")
      assert 10 = eval(s, "(collection/reduce (fn [a x] (+ a x)) 0 (collection/range 5))")
      assert ["a", "b"] = eval(s, ~s|(string/split "a,b" ",")|)
      assert 1 = eval(s, "(math/modulo 7 3)")
    end

    test "a user defn shadows the bare name but the builtin survives under its ns" do
      s = fresh()
      prog = "(do (defn reduce [a b] 999) (list (reduce 1 2) (collection/reduce (fn [a x] (+ a x)) 0 (range 5))))"
      assert [999, 10] = eval(s, prog)
    end

    test "the registry advertises its namespaces" do
      assert "collection" in Stdlib.namespaces()
      assert "math" in Stdlib.namespaces()
      assert Stdlib.builtin?("collection/reduce")
      assert Stdlib.builtin?("reduce")
    end
  end

  describe "mount conflict resolution" do
    test "re-mounting the same namespace is refused, naming the clash" do
      s = fresh()
      assert :ok = Substrate.mount(s, fs(), credentials: %{fs_root: "/tmp"})
      assert {:error, msg} = Substrate.mount(s, fs(), credentials: %{fs_root: "/tmp"})
      assert msg =~ "collision"
      assert msg =~ "fs/read"
    end

    test "`as:` renames the namespace so both coexist" do
      s = fresh()
      :ok = Substrate.mount(s, fs(), credentials: %{fs_root: "/tmp"})
      assert :ok = Substrate.mount(s, fs(), as: "fs2", credentials: %{fs_root: "/tmp"})
      surface = eval(s, "(describe)")
      assert surface =~ "fs/read"
      assert surface =~ "fs2/read"
    end

    test "a substrate may not claim a stdlib namespace" do
      s = fresh()
      sub = "(substrate collection \"x\" (capability collection/x \"y\" (parameters (a string)) (returns (record)) (bind Substrate.FS.read/2)))"
            |> Substrate.read_substrate()
      assert {:error, msg} = Substrate.mount(s, sub, [])
      assert msg =~ "shadows a stdlib namespace"
    end

    test "load surfaces a collision as a raised error" do
      assert_raise ArgumentError, ~r/collision/, fn ->
        Substrate.load(["priv/substrates/fs.lisp", "priv/substrates/fs.lisp"], credentials: %{fs_root: "/tmp"})
      end
    end
  end
end
