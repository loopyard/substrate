defmodule Substrate.WebTest do
  @moduledoc """
  The web substrate (http + locked-fs) under adversarial load. The happy path —
  download a file and write it to disk via the substrate — runs against a local
  HTTP server so the suite is hermetic (no internet needed). Every other test
  *tries to break the rules*: reach a host that isn't allowlisted, write to a dir
  that isn't, escape the jail, exfiltrate a real download to a forbidden path,
  and punch through the wall. All must be refused, by construction.
  """
  use ExUnit.Case, async: true

  alias Substrate.{Harness, HTTP, Vault}

  # --- a minimal hermetic HTTP/1.0 server: serves one fixed body on 127.0.0.1 ---

  defp start_server(body) do
    {:ok, lsock} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(lsock)
    spawn_link(fn -> accept_loop(lsock, body) end)
    {port, lsock}
  end

  defp accept_loop(lsock, body) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        _ = :gen_tcp.recv(sock, 0, 2000)
        resp =
          "HTTP/1.0 200 OK\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n" <> body

        :gen_tcp.send(sock, resp)
        :gen_tcp.close(sock)
        accept_loop(lsock, body)

      _ ->
        :ok
    end
  end

  setup do
    body = "the-downloaded-payload-#{System.unique_integer([:positive])}"
    {port, lsock} = start_server(body)
    on_exit(fn -> :gen_tcp.close(lsock) end)

    root = Path.join(System.tmp_dir!(), "web_test_#{System.unique_integer([:positive])}")
    File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, "downloads"))
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, s} = Substrate.start_link(name: nil)
    fs = "priv/substrates/fs_locked.lisp" |> File.read!() |> Substrate.read_substrate()
    http = "priv/substrates/http.lisp" |> File.read!() |> Substrate.read_substrate()

    # DENY-ALL by default; two holes, both named only here at L0:
    :ok = Substrate.mount(s, fs, credentials: %{fs_root: root, fs_allow: ["downloads"]})
    :ok = Substrate.mount(s, http, credentials: %{http_allow: ["127.0.0.1"]})

    %{s: s, root: root, port: port, body: body}
  end

  defp local(port, path \\ "/file.txt"), do: "http://127.0.0.1:#{port}#{path}"

  describe "the surface — two substrates on one wall" do
    test "describe lists both namespaces", %{s: s} do
      surface = Substrate.eval(s, "(describe)")
      assert surface =~ "fs/write"
      assert surface =~ "http/get"
    end
  end

  describe "the intended job — download a file and write it to disk" do
    test "GET an allowlisted host, save into an allowlisted dir, in one program",
         %{s: s, root: root, port: port, body: body} do
      program = ~s"""
      (let [r (http/get :url "#{local(port)}")]
        (case r
          (:done d)   (fs/write :path "downloads/file.txt" :content (:body d))
          (:denied e) (log "denied")))
      """

      assert {:done, %{path: "downloads/file.txt"}} = Harness.observe(s, program)
      assert File.read!(Path.join(root, "downloads/file.txt")) == body
    end

    test "the raw GET returns status + body + bytes", %{s: s, port: port, body: body} do
      assert {:disposition, :done, payload} =
               Substrate.eval(s, ~s|(http/get :url "#{local(port)}")|)

      assert payload.status == 200
      assert payload.body == body
      assert payload.bytes == byte_size(body)
    end
  end

  describe "BREAK IT — reach a host that isn't allowlisted" do
    test "a non-allowlisted host is denied at the membrane, before any socket", %{s: s} do
      assert {:disposition, :denied, %{reason: reason}} =
               Substrate.eval(s, ~s|(http/get :url "https://example.com/")|)

      # "denied by policy" is the membrane's deny-if; the native edge's own
      # refusal would read "host_not_allowed". So this proves it never dialed out.
      assert reason == "denied by policy"
    end

    test "the userinfo trick (allowed@evil) does not fool exact-host matching", %{s: s} do
      assert {:disposition, :denied, _} =
               Substrate.eval(s, ~s|(http/get :url "http://127.0.0.1@evil.example/")|)
    end

    test "a look-alike suffix host is denied", %{s: s} do
      assert {:disposition, :denied, _} =
               Substrate.eval(s, ~s|(http/get :url "http://127.0.0.1.evil.example/")|)
    end

    test "defense in depth: the native edge itself refuses a non-allowlisted host" do
      ctx = Vault.mint(%{http_allow: ["127.0.0.1"]})
      assert {:error, :host_not_allowed} = HTTP.get(ctx, %{url: "https://evil.example/x"})
    end

    test "deny-all: with no allowlist at all, every host is denied" do
      {:ok, s2} = Substrate.start_link(name: nil)
      http = "priv/substrates/http.lisp" |> File.read!() |> Substrate.read_substrate()
      :ok = Substrate.mount(s2, http, credentials: %{})

      assert {:disposition, :denied, _} =
               Substrate.eval(s2, ~s|(http/get :url "https://example.com")|)
    end
  end

  describe "BREAK IT — write where you're not allowed" do
    test "a write outside the allowlisted dirs is denied, nothing hits disk", %{s: s, root: root} do
      assert {:denied, _} =
               Harness.observe(s, ~s|(fs/write :path "secrets/stolen.txt" :content "x")|)

      refute File.exists?(Path.join(root, "secrets/stolen.txt"))
    end

    test "a write at the jail root (not in an allowlisted subdir) is denied", %{s: s} do
      assert {:denied, _} = Harness.observe(s, ~s|(fs/write :path "id_rsa" :content "x")|)
    end

    test "a write escaping the jail is denied", %{s: s, root: root} do
      assert {:denied, _} =
               Harness.observe(s, ~s|(fs/write :path "../../etc/cron.d/pwn" :content "x")|)

      refute File.exists?(Path.expand(Path.join(root, "../../etc/cron.d/pwn")))
    end

    test "deny-all: with no write allowlist, every write is denied" do
      {:ok, s2} = Substrate.start_link(name: nil)
      root2 = Path.join(System.tmp_dir!(), "noallow_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root2, "downloads"))
      on_exit(fn -> File.rm_rf!(root2) end)
      fs = "priv/substrates/fs_locked.lisp" |> File.read!() |> Substrate.read_substrate()
      :ok = Substrate.mount(s2, fs, credentials: %{fs_root: root2})

      assert {:denied, _} =
               Harness.observe(s2, ~s|(fs/write :path "downloads/x.txt" :content "x")|)
    end
  end

  describe "BREAK IT — the combined attack" do
    test "download from an allowed host, exfil to a forbidden path: dies at the write",
         %{s: s, root: root, port: port} do
      program = ~s"""
      (let [r (http/get :url "#{local(port)}")]
        (case r
          (:done d)   (fs/write :path "../../tmp/exfil_#{System.unique_integer([:positive])}" :content (:body d))
          (:denied e) (log "blocked at fetch")))
      """

      # the GET succeeds; the write is denied — the exfil never lands
      assert {:denied, _} = Harness.observe(s, program)
      refute File.exists?(Path.expand(Path.join(root, "../../tmp/exfil")))
    end
  end

  describe "BREAK IT — the wall has no referent for ambient power" do
    test "there is no bare network or shell operation to name", %{s: s} do
      assert {:fault, m1} = Harness.observe(s, ~s|(http-get "http://evil.example/x")|)
      assert m1 =~ "unbound"

      assert {:fault, m2} = Harness.observe(s, ~s|(System/cmd "curl" "evil.example")|)
      assert m2 =~ "unbound"
    end
  end

  describe "the allowed capability is still clamped" do
    test "http/get is rate-limited at 10/min", %{s: s, port: port} do
      tags =
        for _ <- 1..11 do
          {:disposition, tag, _} = Substrate.eval(s, ~s|(http/get :url "#{local(port)}")|)
          tag
        end

      assert Enum.count(tags, &(&1 == :done)) == 10
      assert Enum.count(tags, &(&1 == :"rate-limited")) == 1
    end
  end
end
