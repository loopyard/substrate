defmodule Substrate.EvalLangTest do
  @moduledoc """
  The control structures that make substrate-Lisp a Turing-complete *computer*,
  not a menu: branching (if/cond/case), iteration (for/break), lexical binding
  (let), first-class functions (fn) and — the piece that closes the loop —
  named recursion via defn. Unbounded recursion is expressible; the guarded
  runtime bounds *execution* (step/time/heap) without bounding the language.
  """
  use ExUnit.Case, async: true

  alias Substrate.Lisp.{Eval, Reader}

  setup do
    {:ok, s} = Substrate.start_link(name: nil)
    %{s: s}
  end

  describe "named recursion (defn sees its own name — letrec)" do
    test "factorial", %{s: s} do
      assert 120 = Substrate.eval(s, "(do (defn f [n] (if (<= n 1) 1 (* n (f (decrement n))))) (f 5))")
    end

    test "accumulator-style recursion", %{s: s} do
      prog = "(do (defn sum [n acc] (if (= n 0) acc (sum (decrement n) (+ acc n)))) (sum 100 0))"
      assert 5050 = Substrate.eval(s, prog)
    end

    test "recursion computing a power", %{s: s} do
      prog = "(do (defn pow [b e] (if (= e 0) 1 (* b (pow b (decrement e))))) (pow 2 10))"
      assert 1024 = Substrate.eval(s, prog)
    end

    test "deep-but-finite recursion completes under the default budget", %{s: s} do
      prog = "(do (defn down [n] (if (= n 0) :done (down (decrement n)))) (down 5000))"
      assert :done = Substrate.eval(s, prog)
    end
  end

  describe "self-application still works (fixpoint via argument-passing)" do
    test "U-combinator factorial", %{s: s} do
      prog = "(do (defn f [self n] (if (<= n 1) 1 (* n (self self (decrement n))))) (f f 5))"
      assert 120 = Substrate.eval(s, prog)
    end
  end

  describe "branching and iteration" do
    test "if / cond / case", %{s: s} do
      assert "big" = Substrate.eval(s, "(if (> 5 3) \"big\" \"small\")")
      assert :b = Substrate.eval(s, "(cond ((= 1 2) :a) ((= 2 2) :b) (true :c))")
      # case matches capability dispositions or the _ wildcard (value switch = cond)
      assert "any" = Substrate.eval(s, "(case 2 _ \"any\")")
    end

    test "for maps a collection; break exits early", %{s: s} do
      assert [1, 4, 9] = Substrate.eval(s, "(for [x (list 1 2 3)] (* x x))")
    end

    test "and / or short-circuit", %{s: s} do
      assert false == Substrate.eval(s, "(and true false)")
      assert 7 = Substrate.eval(s, "(or nil 7)")
    end

    test "let gives lexical scope; fn is first-class", %{s: s} do
      assert 30 = Substrate.eval(s, "(let [x 10 f (fn [y] (* y 3))] (f x))")
    end
  end

  describe "scoping precedence" do
    test "a user defn shadows a builtin of the same name (lexical scoping)", %{s: s} do
      assert 200 = Substrate.eval(s, "(do (defn increment [x] (* x 100)) (increment 2))")
    end

    test "a non-colliding name still reaches the builtin", %{s: s} do
      assert [2, 4, 6] = Substrate.eval(s, "(do (defn double [x] (* x 2)) (map double (list 1 2 3)))")
    end
  end

  describe "the language is unbounded; the runtime is not" do
    test "a named infinite recursion is killed by the step budget, not a hang", %{s: s} do
      forms = Reader.read_all("(do (defn loop [n] (loop (increment n))) (loop 0))", atoms: :existing)
      assert {:fault, msg} = Eval.run_guarded(forms, s, max_steps: 50_000, timeout: 3_000)
      assert msg =~ "step budget"
    end
  end

  describe "mutual recursion (letrec*: defns in a sequence see each other)" do
    test "forward reference across two defns resolves both directions", %{s: s} do
      prog = "(do (defn a [n] (if (= n 0) :a (b (decrement n)))) (defn b [n] (if (= n 0) :b (a (decrement n)))) (a 3))"
      assert :b = Substrate.eval(s, prog)
    end

    test "a defn still closes over an earlier non-function binding (sequential)", %{s: s} do
      assert 42 = Substrate.eval(s, "(do (def x 42) (defn get-x [] x) (get-x))")
    end
  end

  describe "attempt: failure becomes a value (a disposition), recoverable in one emission" do
    test "success returns (:ok value)", %{s: s} do
      assert {:disposition, :ok, 3} = Substrate.eval(s, "(attempt (+ 1 2))")
    end

    test "a fault returns (:fault {message …}) instead of killing the emission", %{s: s} do
      assert {:disposition, :fault, %{message: msg}} = Substrate.eval(s, "(attempt (/ 1 0))")
      assert msg =~ "division by zero"
    end

    test "an unbound symbol is caught as a fault, not a crash", %{s: s} do
      assert {:disposition, :fault, %{message: msg}} = Substrate.eval(s, "(attempt (frobnicate))")
      assert msg =~ "unbound"
    end

    test "the existing case matcher unwraps it — recover and continue", %{s: s} do
      prog = "(case (attempt (/ 1 0)) (:ok v) v (:fault e) (:message e))"
      assert "division by zero" = Substrate.eval(s, prog)

      ok = "(case (attempt (* 6 7)) (:ok v) v (:fault e) :failed)"
      assert 42 = Substrate.eval(s, ok)
    end

    test "bindings made inside attempt never leak out (env in = env out)", %{s: s} do
      # `x` is bound *inside* the attempt; referencing it afterwards must fault.
      assert {:fault, msg} = Substrate.eval(s, "(do (attempt (def x 99)) x)")
      assert msg =~ "unbound"
    end

    # The wall: `attempt` rescues exceptions, but the step budget is a `throw`.
    # Wrapping a bomb in `attempt` must NOT let it escape the budget — the kill
    # unwinds straight past `attempt` to the guarded boundary.
    test "attempt CANNOT swallow the step-budget kill", %{s: s} do
      src = "(attempt (do (defn loop [n] (loop (increment n))) (loop 0)))"
      forms = Reader.read_all(src, atoms: :existing)
      assert {:fault, msg} = Eval.run_guarded(forms, s, max_steps: 50_000, timeout: 3_000)
      assert msg =~ "step budget"
    end
  end
end
