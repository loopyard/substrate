defmodule HardeningTest do
  @moduledoc """
  The substrate Lisp is the *only* surface an untrusted agent touches, so its
  reader and evaluator are the trust boundary. These tests assert the boundary
  holds against the BEAM-specific abuse vectors: atom-table exhaustion, runaway
  compute, allocation/recursion bombs, and pathological source — every one
  returns a clean `{:fault, _}` instead of harming the node.

  (Recursion here is by self-application — `(rec rec)` — because a closure
  captures its environment *before* it is bound to its own name, so a plain
  `(defn loop [] (loop))` can't see itself. That non-termination is exactly why
  the step/heap/timeout guards are needed.)
  """
  use ExUnit.Case, async: false

  alias Substrate.Lisp.{Reader, Eval}

  setup do
    {:ok, s} = Substrate.start_link(name: nil)
    %{s: s}
  end

  describe "atom-table safety (reader, :existing mode)" do
    test "a brand-new keyword is refused, not interned", %{s: s} do
      assert {:fault, msg} = Substrate.eval(s, "(:zzz_brand_new_keyword_xyz {})")
      assert msg =~ "unknown keyword"
    end

    test "flooding distinct novel keywords does not grow the atom table", %{s: s} do
      before = :erlang.system_info(:atom_count)

      Enum.each(1..300, fn i ->
        assert {:fault, _} = Substrate.eval(s, "(:flood_novel_#{i} {})")
      end)

      # Under the old String.to_atom path this would have added ~300 atoms.
      assert :erlang.system_info(:atom_count) - before < 10
    end

    test "keywords already on the surface still work", %{s: s} do
      assert Substrate.eval(s, ~s|(let [m {:done 1}] (:done m))|) == 1
    end
  end

  describe "resource bounds (evaluator)" do
    test "infinite recursion is stopped by the step budget", %{s: s} do
      forms = Reader.read_all("(do (defn rec [f] (f f)) (rec rec))", atoms: :existing)
      assert {:fault, msg} = Eval.run_guarded(forms, s, max_steps: 50_000, timeout: 5_000)
      assert msg =~ "step budget"
    end

    test "wall-clock timeout fires when steps are unbounded", %{s: s} do
      forms = Reader.read_all("(do (defn rec [f] (f f)) (rec rec))", atoms: :existing)
      assert {:fault, msg} = Eval.run_guarded(forms, s, max_steps: nil, timeout: 100)
      assert msg =~ "timed out"
    end

    test "a recursion/heap bomb is killed by the per-process heap cap", %{s: s} do
      prog = "(do (defn g [f n] (if (= n 0) 0 (increment (f f (decrement n))))) (g g 3000000))"
      forms = Reader.read_all(prog, atoms: :existing)
      assert {:fault, msg} = Eval.run_guarded(forms, s, max_heap: 200_000, max_steps: nil, timeout: 10_000)
      assert msg =~ "heap limit"
    end

    test "a normal program runs fine under the guard", %{s: s} do
      assert Substrate.eval(s, "(+ 1 2 3)") == 6
      assert Substrate.eval(s, "(do (defn sq [x] (* x x)) (sq 9))") == 81
    end
  end

  describe "parser bounds (reader)" do
    test "absurd nesting is refused before the stack blows", %{s: s} do
      assert {:fault, msg} = Substrate.eval(s, String.duplicate("(", 1000))
      assert msg =~ "nesting too deep"
    end

    test "oversized source is refused before tokenizing", %{s: s} do
      assert {:fault, msg} = Substrate.eval(s, String.duplicate("a", 300 * 1024))
      assert msg =~ "source too large"
    end
  end
end
