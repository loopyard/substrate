defmodule Substrate.ConsoleTest do
  @moduledoc """
  Drives the trusted L2 operator console (`Substrate.Console`) end to end by
  feeding it a scripted session over a captured stdio and asserting on what it
  prints. The console is the *build & debug* side of the wall — the counterpart
  to the agent-facing `Substrate.Repl`. These tests pin the authoring verbs
  (mount/revoke/restore/reveal, the approval queue) and, crucially, that the
  wall still holds: the operator's `\\reveal` X-rays a capability's hidden policy
  rules, but the bare agent `(describe …)` it can also run does not.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Substrate.Console

  # Run `lines` through a fresh console and return everything it printed.
  defp session(server, lines) do
    input = Enum.map_join(lines, "\n", & &1) <> "\n\\q\n"
    capture_io(input, fn -> Console.loop(server) end)
  end

  setup do
    root = Path.join(System.tmp_dir!(), "console_test_#{System.unique_integer([:positive])}")
    File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, "notes"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, server} = Substrate.start_link(name: nil)
    %{server: server, root: root}
  end

  test "starts on an empty surface and builds it up with \\mount", %{server: server} do
    out =
      session(server, [
        "\\mount priv/substrates/roots.lisp"
      ])

    assert out =~ "empty surface"
    assert out =~ "mounted priv/substrates/roots.lisp"
    # the freshly-mounted surface is echoed back
    assert out =~ "fs/write"
  end

  test "\\reveal X-rays policy rules the agent's (describe) hides", %{server: server} do
    out =
      session(server, [
        "\\mount priv/substrates/roots.lisp",
        "\\reveal fs/write",
        "(describe fs/write)"
      ])

    # The session renders fs/write twice: once via the trusted \reveal (which
    # shows the policy rule) and once via the agent-seam (describe fs/write)
    # (which must not). So the rule name appears exactly once — proof the X-ray
    # is operator-only and the wall held on the untrusted path.
    assert out =~ "policy"
    assert out =~ "outside-roots"
    assert length(String.split(out, "outside-roots")) - 1 == 1
  end

  test "\\revoke suspends a capability; bare eval then sees :denied", %{server: server} do
    out =
      session(server, [
        "\\mount priv/substrates/roots.lisp",
        "\\revoke fs/write",
        ~s|(fs/write :path "/home/a/x.txt" :content "hi")|,
        "\\restore fs/write",
        ~s|(fs/write :path "/home/a/x.txt" :content "hi")|
      ])

    assert out =~ "revoked fs/write"
    assert out =~ ~s|:denied|
    assert out =~ "capability suspended"
    assert out =~ "restored fs/write"
    assert out =~ ~s|:done|
  end

  test "the approval queue: write parks, \\queue lists, \\approve runs it", %{
    server: server,
    root: root
  } do
    out =
      session(server, [
        "\\mount priv/substrates/fs.lisp --cred fs_root=#{root}",
        ~s|(fs/write :path "secret/x.txt" :content "parked")|,
        "\\queue",
        "\\approve eff_1",
        "\\queue"
      ])

    assert out =~ ~s|:queued|
    # \queue shows the parked effect with its handle and args
    assert out =~ "eff_1  fs/write"
    assert out =~ "parked"
    # \approve lets it run for real
    assert out =~ ~s|:done|
    assert File.read!(Path.join(root, "secret/x.txt")) == "parked"
    # the queue is empty afterward
    assert out =~ "no effects awaiting review"
  end

  test "\\deny rejects a parked effect without running it", %{server: server, root: root} do
    out =
      session(server, [
        "\\mount priv/substrates/fs.lisp --cred fs_root=#{root}",
        ~s|(fs/write :path "secret/y.txt" :content "nope")|,
        "\\deny eff_1"
      ])

    assert out =~ ~s|:denied|
    assert out =~ "rejected by human"
    refute File.exists?(Path.join(root, "secret/y.txt"))
  end

  test "\\audit records every adjudicated call on the trusted side", %{server: server} do
    out =
      session(server, [
        "\\mount priv/substrates/roots.lisp",
        ~s|(fs/write :path "/home/a/x.txt" :content "hi")|,
        ~s|(fs/write :path "/root/x.txt" :content "no")|,
        "\\audit"
      ])

    # both the allowed and the policy-denied write show up, oldest first
    assert out =~ ~r/#1\s+fs\/write\s+->\s+:done/
    assert out =~ ~r/#2\s+fs\/write\s+->\s+:denied/
  end
end
