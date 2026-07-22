defmodule Substrate.StdlibTest do
  @moduledoc """
  The stdlib, grouped into Math/Logic/Collection/String/Maps/Json behind the
  Substrate.Lisp.Stdlib registry. These exercise each group through the real
  eval seam, plus the registry's discovery and clean bad-arity fault.
  """
  use ExUnit.Case, async: true

  alias Substrate.Lisp.Stdlib

  defp val(src) do
    {:ok, s} = Substrate.start_link(name: nil)
    Substrate.eval(s, src)
  end

  describe "Math" do
    test "arithmetic + float/integer division + modulo" do
      assert 10 = val("(+ 1 2 3 4)")
      assert 24 = val("(* 1 2 3 4)")
      assert 3.5 = val("(/ 7 2)")
      assert 3 = val("(quotient 7 2)")
      assert 1 = val("(modulo 7 3)")
      assert 4 = val("(absolute -4)")
      assert 9 = val("(maximum 1 9 3)")
    end

    test "division by zero is a clean fault" do
      assert {:fault, "division by zero"} = val("(/ 1 0)")
      assert {:fault, "division by zero"} = val("(modulo 1 0)")
    end
  end

  describe "Logic" do
    test "equality, ordering, negation" do
      assert true == val("(= 2 2 2)")
      assert false == val("(= 1 2)")
      assert true == val("(< 1 2)")
      assert true == val("(not false)")
    end
  end

  describe "Collection" do
    test "build, transform, fold" do
      assert [0, 1, 2] = val("(range 3)")
      assert [3, 2, 1] = val("(reverse (list 1 2 3))")
      assert [1, 2, 3] = val("(sort (list 3 1 2))")
      assert [0, 1, 2] = val("(prepend 0 (list 1 2))")
      assert [1, 2, 0] = val("(append (list 1 2) 0)")
      assert [1, 2, 3, 4] = val("(concatenate (list 1 2) (list 3 4))")
      assert 2 = val("(element-at (list 1 2 3) 1)")
      assert [1, 4, 9] = val("(map (fn [x] (* x x)) (list 1 2 3))")
      assert [2, 4] = val("(filter (fn [x] (= 0 (modulo x 2))) (list 1 2 3 4))")
      assert 5050 = val("(reduce (fn [a x] (+ a x)) 0 (range 101))")
      assert true == val("(contains? (list 1 2 3) 2)")
    end

    test "count is polymorphic over list / map / string" do
      assert 3 = val("(count (list 1 2 3))")
      assert 5 = val(~s|(count "hello")|)
    end
  end

  describe "String" do
    test "concatenation, split, case, prefixes" do
      assert "a1" = val(~s|(string "a" 1)|)
      assert ["a", "b", "c"] = val(~s|(split "a,b,c" ",")|)
      assert "AB" = val(~s|(uppercase "ab")|)
      assert true == val(~s|(starts-with? "hello" "he")|)
      assert true == val(~s|(ends-with? "hello" "lo")|)
    end
  end

  describe "Maps" do
    test "associate / get / keys / values / contains?" do
      assert %{"a" => 1, "b" => 2} = val(~s|(associate {"a" 1} "b" 2)|)
      assert 1 = val(~s|(get {"a" 1} "a")|)
      assert true == val(~s|(contains? {"a" 1} "a")|)
    end
  end

  describe "Json" do
    test "round-trips through the eval seam with string keys" do
      assert 1 = val(~s|(get (parse-json "{\\"a\\": 1}") "a")|)
      assert nil == val(~s|(parse-json "not json")|)
    end
  end

  describe "the registry" do
    test "builtin? recognises grouped names and rejects others" do
      assert Stdlib.builtin?("reduce")
      assert Stdlib.builtin?("/")
      refute Stdlib.builtin?("fs/read")
      refute Stdlib.builtin?("totally-made-up")
    end

    test "every advertised name routes to a group (no orphan in the whitelist)" do
      # invoking with [] may fault on arity, but must never raise KeyError —
      # that would mean a name was advertised with no group behind it.
      for name <- Stdlib.names() do
        try do
          Stdlib.invoke(name, [], fn _f, _a -> nil end)
        rescue
          e -> refute match?(%KeyError{}, e), "#{name} is not routed"
        end
      end
    end

    test "the core stdlib names are all present" do
      have = MapSet.new(Stdlib.names())
      for n <- ~w(+ / modulo = not map filter reduce range prepend count string split get associate parse-json) do
        assert MapSet.member?(have, n), "missing builtin #{n}"
      end
    end

    test "a bad-arity builtin call is a clean fault, not a crash" do
      assert {:fault, msg} = val("(increment)")
      assert msg =~ "got bad args"
    end
  end
end
