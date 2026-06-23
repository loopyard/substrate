defmodule Substrate.ReaderDiagnosticsTest do
  @moduledoc """
  The reader is error-tolerant: it recovers past each syntax slip, finds every
  problem in one pass, and points at each with a line/column (and a caret, via
  format_diagnostics/2). read_all/2 stays strict — it raises an aggregated,
  located fault — while diagnose/2 never raises and returns the full list.
  """
  use ExUnit.Case, async: true

  alias Substrate.Lisp.Reader
  alias Substrate.Lisp.Error

  describe "clean source" do
    test "diagnose returns {:ok, forms} and the AST is unchanged" do
      assert {:ok, forms} = Reader.diagnose(~s|(fs/read :path "x")|, atoms: :create)
      assert forms == [{:list, [{:sym, "fs/read"}, {:kw, :path}, {:str, "x"}]}]
    end

    test "read_all still parses valid multi-form source" do
      assert [{:int, 1}, {:list, [{:sym, "f"}, {:int, 2}]}] = Reader.read_all("1 (f 2)")
    end
  end

  describe "locating a single problem" do
    test "an unclosed ( points at the opener" do
      assert {:error, [d]} = Reader.diagnose("(foo (bar 1)")
      assert d.line == 1 and d.col == 1
      assert d.message =~ "unclosed `(`"
    end

    test "an extra ) points at the closer" do
      assert {:error, [d]} = Reader.diagnose("(a)\n  )")
      assert d.line == 2 and d.col == 3
      assert d.message =~ "unexpected `)`"
    end

    test "an unterminated string points at the opening quote" do
      assert {:error, ds} = Reader.diagnose(~s|(x "ab|)
      term = Enum.find(ds, &(&1.message =~ "unterminated string"))
      assert term.line == 1 and term.col == 4
    end

    test "a mismatched delimiter names both delimiters" do
      assert {:error, [d]} = Reader.diagnose("(let [a 1) a)")
      assert d.message =~ "mismatched delimiter"
      assert d.message =~ "`[`" and d.message =~ "`)`"
    end

    test "column tracking survives newlines, tabs and comments" do
      src = "; a comment\n(ok)\n\t  )"
      assert {:error, [d]} = Reader.diagnose(src)
      assert d.line == 3
      assert d.message =~ "unexpected `)`"
    end
  end

  describe "error tolerance — every problem in one pass" do
    test "two stray closers are both found and sorted by position" do
      assert {:error, [d1, d2]} = Reader.diagnose("(a)) (b))")
      assert {d1.line, d1.col} == {1, 4}
      assert {d2.line, d2.col} == {1, 9}
    end

    test "an unterminated string and the unclosed list it sits in are both reported" do
      assert {:error, ds} = Reader.diagnose(~s|(f "oops|)
      assert Enum.any?(ds, &(&1.message =~ "unterminated string"))
      assert Enum.any?(ds, &(&1.message =~ "unclosed `(`"))
    end
  end

  describe "the agent path (:existing) — located, and mints nothing" do
    test "an unknown keyword is a located diagnostic, not a raise" do
      assert {:error, [d]} = Reader.diagnose("(:no_such_surface_kw_abc {})", atoms: :existing)
      assert d.message =~ "unknown keyword"
      assert d.line == 1 and d.col == 2
    end

    test "recovering past an unknown keyword does not grow the atom table" do
      novel = "kw_that_must_never_be_interned_#{System.unique_integer([:positive])}"
      assert {:error, _} = Reader.diagnose("(:#{novel} {})", atoms: :existing)
      assert_raise ArgumentError, fn -> String.to_existing_atom(novel) end
    end
  end

  describe "rendering and the strict path" do
    test "format_diagnostics draws a caret under the column" do
      {:error, ds} = Reader.diagnose("(a\n   ]")
      out = Reader.format_diagnostics("(a\n   ]", ds)
      assert out =~ "line "
      assert out =~ "^"
      # caret sits under the offending char on its own line
      assert Enum.any?(String.split(out, "\n"), &(String.trim_leading(&1) == "^"))
    end

    test "read_all/2 raises a located, counted fault" do
      err = assert_raise Error, fn -> Reader.read_all("(a)) (b))") end
      assert err.message =~ "2 syntax errors"
      assert err.message =~ "column"
    end

    test "preserved limits still raise their familiar messages" do
      assert_raise Error, ~r/nesting too deep/, fn -> Reader.read_all(String.duplicate("(", 1000)) end
      big = String.duplicate("a", 300 * 1024)
      assert_raise Error, ~r/source too large/, fn -> Reader.read_all(big) end
    end
  end
end
