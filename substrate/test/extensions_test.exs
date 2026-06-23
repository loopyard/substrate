defmodule Substrate.ExtensionsTest do
  @moduledoc """
  The substrate's authoring/runtime extensions, each with its security guard:

    * `load/2`            — a substrate file becomes a running substrate
    * secrets + auth      — the trusted side authenticates; the agent holds nothing
    * audit log           — every adjudicated call is recorded trusted-side
    * readable `describe` — the RULE is shown, the VALUE stays vaulted
    * `grant` / `as`      — the agent attenuates a child surface, never widens it
  """
  use ExUnit.Case, async: false

  alias Substrate.Harness

  # --- a hermetic HTTP/1.0 server that captures the request it received ---

  defp start_server(body, capture_to) do
    {:ok, lsock} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(lsock)
    spawn_link(fn -> accept_loop(lsock, body, capture_to) end)
    {port, lsock}
  end

  defp accept_loop(lsock, body, capture_to) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        {:ok, req} = :gen_tcp.recv(sock, 0, 2000)
        send(capture_to, {:request, req})
        resp = "HTTP/1.0 200 OK\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n" <> body
        :gen_tcp.send(sock, resp)
        :gen_tcp.close(sock)
        accept_loop(lsock, body, capture_to)

      _ ->
        :ok
    end
  end

  describe "load/2 — the artifact becomes the runtime" do
    setup do
      root = Path.join(System.tmp_dir!(), "load_#{System.unique_integer([:positive])}")
      File.rm_rf!(root)
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      %{root: root}
    end

    test "loading a substrate file gives a working substrate", %{root: root} do
      {:ok, s} = Substrate.load("priv/substrates/dir.lisp", credentials: %{fs_root: root})

      assert Substrate.eval(s, "(describe)") =~ "dir/write"
      assert {:disposition, :done, _} =
               Substrate.eval(s, ~s|(dir/write :path "x.txt" :content "hi")|)

      assert File.read!(Path.join(root, "x.txt")) == "hi"
    end
  end

  describe "roots.lisp — absolute paths, allowlist of roots (/home yes, /root no)" do
    setup do
      base = Path.join(System.tmp_dir!(), "roots_#{System.unique_integer([:positive])}")
      allowed = Path.join(base, "home")
      forbidden = Path.join(base, "root")
      File.rm_rf!(base)
      File.mkdir_p!(allowed)
      File.mkdir_p!(forbidden)
      on_exit(fn -> File.rm_rf!(base) end)

      # the file declares ["/home"]; the integrator pins it to a tmp root for the test
      {:ok, s} = Substrate.load("priv/substrates/roots.lisp", credentials: %{fs_roots: [allowed]})
      %{s: s, allowed: allowed, forbidden: forbidden}
    end

    test "a write inside an allowed root goes through", %{s: s, allowed: allowed} do
      assert {:disposition, :done, _} =
               Substrate.eval(s, ~s|(fs/write :path "#{allowed}/notes.txt" :content "buy milk")|)

      assert File.read!(Path.join(allowed, "notes.txt")) == "buy milk"
    end

    test "a write outside every allowed root is denied — nothing hits the disk",
         %{s: s, forbidden: forbidden} do
      target = Path.join(forbidden, "authorized_keys")

      assert {:disposition, :denied, %{reason: "denied by policy"}} =
               Substrate.eval(s, ~s|(fs/write :path "#{target}" :content "attacker")|)

      refute File.exists?(target)
    end

    test "`..` cannot climb out of an allowed root", %{s: s, allowed: allowed, forbidden: forbidden} do
      escape = "#{allowed}/../root/pwned.txt"

      assert {:disposition, :denied, _} =
               Substrate.eval(s, ~s|(fs/write :path "#{escape}" :content "via dotdot")|)

      refute File.exists?(Path.join(forbidden, "pwned.txt"))
    end

    test "reads obey the same allowlist", %{s: s, allowed: allowed, forbidden: forbidden} do
      File.write!(Path.join(allowed, "ok.txt"), "hi")
      File.write!(Path.join(forbidden, "secret.txt"), "nope")

      assert {:disposition, :done, %{content: "hi"}} =
               Substrate.eval(s, ~s|(fs/read :path "#{Path.join(allowed, "ok.txt")}")|)

      assert {:disposition, :denied, _} =
               Substrate.eval(s, ~s|(fs/read :path "#{Path.join(forbidden, "secret.txt")}")|)
    end
  end

  describe "secrets + auth — authenticated on the trusted side, opaque to the agent" do
    setup do
      token = "s3cr3t-#{System.unique_integer([:positive])}"
      System.put_env("SUBSTRATE_TEST_TOKEN", token)
      on_exit(fn -> System.delete_env("SUBSTRATE_TEST_TOKEN") end)

      {port, lsock} = start_server("ok", self())
      on_exit(fn -> :gen_tcp.close(lsock) end)

      {:ok, s} = Substrate.load("test/fixtures/authed.lisp")
      %{s: s, port: port, token: token}
    end

    test "the bearer token is injected into the real request", %{s: s, port: port, token: token} do
      assert {:disposition, :done, _} =
               Substrate.eval(s, ~s|(authed/get :url "http://127.0.0.1:#{port}/")|)

      assert_receive {:request, req}, 2000
      # :httpc lowercases header names on the wire; the value is what matters
      assert String.downcase(req) =~ "authorization: bearer #{String.downcase(token)}"
    end

    test "the agent can never retrieve the token through eval or describe",
         %{s: s, token: token} do
      # describe leaks neither the secret value, the auth template, nor the bind.
      # (The docstring may *mention* a token — honest-but-abstract — but the
      # actual secret, header name, and auth/secret forms never appear.)
      surface = Substrate.eval(s, "(describe authed/get)")
      refute surface =~ token
      refute surface =~ "Authorization"
      refute surface =~ "(auth"
      refute surface =~ "secret"
      refute surface =~ "bind"

      # there is no L2 form that returns a credential — `secret` has no referent
      assert {:fault, msg} = Harness.observe(s, "(secret :token)")
      assert msg =~ "unbound"
      refute inspect(Harness.observe(s, "(describe)")) =~ token
    end
  end

  describe "audit log — trusted-side observability of every call" do
    setup do
      System.put_env("SUBSTRATE_TEST_TOKEN", "tok")
      on_exit(fn -> System.delete_env("SUBSTRATE_TEST_TOKEN") end)
      {port, lsock} = start_server("ok", self())
      on_exit(fn -> :gen_tcp.close(lsock) end)
      {:ok, s} = Substrate.load("test/fixtures/authed.lisp")
      %{s: s, port: port}
    end

    test "allowed and denied calls are both recorded, in order", %{s: s, port: port} do
      Substrate.eval(s, ~s|(authed/get :url "http://127.0.0.1:#{port}/")|)
      Substrate.eval(s, ~s|(authed/get :url "https://evil.example/")|)

      log = Substrate.audit(s)
      assert length(log) == 2
      assert [%{cap: "authed/get", outcome: {:done, _}}, %{cap: "authed/get", outcome: {:denied, _}}] = log
    end
  end

  describe "readable describe — the rule is shown, the value is not" do
    setup do
      root = Path.join(System.tmp_dir!(), "reveal_#{System.unique_integer([:positive])}")
      File.rm_rf!(root)
      File.mkdir_p!(Path.join(root, "downloads"))
      on_exit(fn -> File.rm_rf!(root) end)
      %{root: root}
    end

    test "reveal_rules shows the glossed guard but never the allowlist value", %{root: root} do
      {:ok, s} =
        Substrate.load("priv/substrates/fs_locked.lisp",
          credentials: %{fs_root: root, fs_allow: ["downloads"]},
          reveal_rules: true
        )

      desc = Substrate.eval(s, "(describe fs/write)")
      # the RULE is now legible to the agent…
      assert desc =~ "guard"
      assert desc =~ "allowlisted directories"
      # …but the VALUE (which dir, the jail root) never crosses the wall
      refute desc =~ "downloads"
      refute desc =~ root
    end

    test "default (abstract) posture still hides deny-if entirely", %{root: root} do
      {:ok, s} =
        Substrate.load("priv/substrates/fs_locked.lisp",
          credentials: %{fs_root: root, fs_allow: ["downloads"]}
        )

      desc = Substrate.eval(s, "(describe fs/write)")
      refute desc =~ "guard"
      refute desc =~ "downloads"
      # the rate limit is still surfaced — only the deny-if rule is withheld
      assert desc =~ "rate"
    end
  end

  describe "grant / as — the agent attenuates, and can only ever narrow" do
    setup do
      root = Path.join(System.tmp_dir!(), "grant_#{System.unique_integer([:positive])}")
      File.rm_rf!(root)
      for d <- ~w(downloads cache), do: File.mkdir_p!(Path.join(root, d))
      on_exit(fn -> File.rm_rf!(root) end)

      # parent may write to downloads AND cache
      {:ok, s} =
        Substrate.load("priv/substrates/fs_locked.lisp",
          credentials: %{fs_root: root, fs_allow: ["downloads", "cache"]}
        )

      %{s: s, root: root}
    end

    test "a granted child can do what it was given", %{s: s, root: root} do
      program = ~s"""
      (let [child (grant :caps [fs/write] :fs_allow ["downloads"])]
        (as child (fs/write :path "downloads/ok.txt" :content "hi")))
      """

      assert {:done, _} = Harness.observe(s, program)
      assert File.read!(Path.join(root, "downloads/ok.txt")) == "hi"
    end

    test "the child cannot reach what the parent kept back (narrower allowlist)", %{s: s, root: root} do
      # parent CAN write cache/; the child was granted only downloads/
      program = ~s"""
      (let [child (grant :caps [fs/write] :fs_allow ["downloads"])]
        (as child (fs/write :path "cache/sneak.txt" :content "x")))
      """

      assert {:denied, _} = Harness.observe(s, program)
      refute File.exists?(Path.join(root, "cache/sneak.txt"))
    end

    test "widening is refused: granting a dir outside the parent's allowlist is denied", %{s: s} do
      # "secrets" is not within downloads/ or cache/ — cannot be granted
      assert {:denied, %{reason: reason}} =
               Harness.observe(s, ~s|(grant :caps [fs/write] :fs_allow ["secrets"])|)

      assert reason =~ "widen"
    end

    test "granting a capability the parent does not hold is denied", %{s: s} do
      assert {:denied, %{reason: reason}} =
               Harness.observe(s, ~s|(grant :caps [http/get] :fs_allow ["downloads"])|)

      assert reason =~ "not held"
    end

    test "a rate ceiling only ever tightens: 3/min granted, the 4th call is clamped", %{s: s} do
      program = ~s"""
      (let [child (grant :caps [fs/write] :fs_allow ["downloads"] :rate "3/min")]
        (as child
          (for [i [1 2 3 4]]
            (fs/write :path "downloads/r.txt" :content "x"))))
      """

      assert {:value, results} = Harness.observe(s, program)
      tags = Enum.map(results, fn {:disposition, tag, _} -> tag end)
      assert Enum.count(tags, &(&1 == :done)) == 3
      assert Enum.count(tags, &(&1 == :"rate-limited")) == 1
    end
  end
end
