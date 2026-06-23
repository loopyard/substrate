defmodule Substrate.HTTPWriteTest do
  @moduledoc """
  The write verbs (post/put/patch/delete) under the same wall as GET, against a
  hermetic local server that echoes back the method it saw and the body byte
  count — so we prove the verb and body actually crossed the socket, the JSON
  body was encoded, and the JSON reply was decoded into :json. Plus the pure
  json builtins, and that a write to a non-allowlisted host dies at the membrane.
  """
  use ExUnit.Case, async: true

  alias Substrate.{Harness, JSON}

  # --- a hermetic server that reports back {method, body_bytes} as JSON ---
  defp start_server do
    {:ok, lsock} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(lsock)
    spawn_link(fn -> accept_loop(lsock) end)
    port
  end

  defp accept_loop(lsock) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        req = recv_all(sock, "")
        method = req |> String.split(" ", parts: 2) |> hd()
        body = case String.split(req, "\r\n\r\n", parts: 2) do
          [_, b] -> b
          _ -> ""
        end
        reply = JSON.encode(%{"method" => method, "body_bytes" => byte_size(body)})
        resp = "HTTP/1.0 200 OK\r\nContent-Length: #{byte_size(reply)}\r\nConnection: close\r\n\r\n" <> reply
        :gen_tcp.send(sock, resp)
        :gen_tcp.close(sock)
        accept_loop(lsock)

      _ ->
        :ok
    end
  end

  # accumulate until the client goes idle (it sends the whole request, then waits)
  defp recv_all(sock, acc) do
    case :gen_tcp.recv(sock, 0, 400) do
      {:ok, chunk} -> recv_all(sock, acc <> chunk)
      {:error, _} -> acc
    end
  end

  setup do
    port = start_server()
    {:ok, s} = Substrate.start_link(name: nil)
    http = "priv/substrates/http.lisp" |> File.read!() |> Substrate.read_substrate()
    :ok = Substrate.mount(s, http, credentials: %{http_allow: ["127.0.0.1"]})
    %{s: s, url: "http://127.0.0.1:#{port}/x"}
  end

  test "POST sends the verb and a JSON-encoded map body; reply decodes to :json", %{s: s, url: url} do
    body = %{"name" => "widget", "qty" => 3}
    program = ~s|(http/post :url "#{url}" :body {"name" "widget" "qty" 3})|

    assert {:disposition, :done, payload} = Substrate.eval(s, program)
    assert payload.status == 200
    assert payload.json["method"] == "POST"
    assert payload.json["body_bytes"] == byte_size(JSON.encode(body))
  end

  test "PATCH threads its own verb through", %{s: s, url: url} do
    assert {:done, %{json: j}} = Harness.observe(s, ~s|(http/patch :url "#{url}" :body {"state" "closed"})|)
    assert j["method"] == "PATCH"
    assert j["body_bytes"] > 0
  end

  test "DELETE carries no body", %{s: s, url: url} do
    assert {:done, %{json: j}} = Harness.observe(s, ~s|(http/delete :url "#{url}")|)
    assert j["method"] == "DELETE"
    assert j["body_bytes"] == 0
  end

  test "a string body is sent as-is (not re-encoded)", %{s: s, url: url} do
    assert {:done, %{json: j}} = Harness.observe(s, ~s|(http/post :url "#{url}" :body "raw-text")|)
    assert j["method"] == "POST"
    assert j["body_bytes"] == byte_size("raw-text")
  end

  test "a write to a non-allowlisted host dies at the membrane", %{s: s} do
    assert {:disposition, :denied, _} =
             Substrate.eval(s, ~s|(http/post :url "https://evil.example/x" :body {"a" 1})|)
  end

  describe "pure json builtins — no authority, no wall" do
    test "parse-json yields a string-keyed map readable with get", %{s: s} do
      assert {:value, 1} = Harness.observe(s, ~s|(get (parse-json "{\\"a\\": 1, \\"b\\": 2}") "a")|)
    end

    test "parse-json on garbage is nil, not a fault", %{s: s} do
      assert {:value, nil} = Harness.observe(s, ~s|(parse-json "not json")|)
    end

    test "to-json round-trips a map", %{s: s} do
      assert {:text, body} = Harness.observe(s, ~s|(to-json {"x" 10})|)
      assert JSON.decode!(body) == %{"x" => 10}
    end
  end
end
