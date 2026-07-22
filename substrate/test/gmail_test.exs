defmodule Substrate.GmailTest do
  @moduledoc """
  The Gmail slice, proven end to end with **no network**: a fake transport is
  injected through the L0 vault (`:__http__`), so `search`/`read` run immediately
  while `gmail/send` is *enqueued* by `(confirm-if always)` and only crosses the
  wire when a human approves it. The point under test is the operator's loop —
  "queue the send, a human reviews the exact fields and releases it" — and that
  the OAuth token is woven in trusted-side without the agent ever seeing it.
  """
  use ExUnit.Case, async: true

  alias Substrate.{Gmail, Server}

  # A fake transport: records every request to the test process, then answers
  # with canned Gmail JSON keyed by the endpoint.
  defp fake_transport(test_pid) do
    fn req ->
      send(test_pid, {:http, req.method, req.url, req[:headers]})

      cond do
        String.contains?(req.url, "/messages/send") ->
          {:ok, %{status: 200, body: ~s|{"id":"sent123","threadId":"t9"}|}}

        String.contains?(req.url, "/messages/m1") ->
          {:ok, %{status: 200, body: read_fixture()}}

        String.contains?(req.url, "/messages?") ->
          {:ok, %{status: 200, body: ~s|{"messages":[{"id":"m1"},{"id":"m2"}]}|}}

        true ->
          {:ok, %{status: 404, body: ~s|{"error":{"message":"not found"}}|}}
      end
    end
  end

  defp read_fixture do
    Substrate.JSON.encode(%{
      "id" => "m1",
      "threadId" => "t1",
      "snippet" => "Hey, are we still on for lunch?",
      "payload" => %{
        "mimeType" => "text/plain",
        "headers" => [
          %{"name" => "From", "value" => "Jane <jane@acme.com>"},
          %{"name" => "Subject", "value" => "Lunch?"},
          %{"name" => "Date", "value" => "Mon, 23 Jun 2026 09:00:00 -0700"}
        ],
        "body" => %{"data" => Gmail.b64url("Hey, are we still on for lunch on Friday?")}
      }
    })
  end

  setup do
    {:ok, server} = Substrate.start_link(name: nil)
    ast = "priv/substrates/gmail.lisp" |> File.read!() |> Substrate.read_substrate()

    # Explicit credentials win over the file's `(secret … (env …))`, so the test
    # needs no GMAIL_TOKEN in the environment. __http__ injects the fake edge.
    :ok =
      Substrate.mount(server, ast,
        credentials: %{gmail_token: "test-token", __http__: fake_transport(self())}
      )

    %{server: server}
  end

  describe "reads run immediately (no confirm)" do
    test "gmail/search returns matching ids", %{server: server} do
      assert {:disposition, :done, payload} =
               Server.call(server, "gmail/search", %{query: "is:unread"})

      assert payload.ids == ["m1", "m2"]
      assert payload.count == 2
      assert_received {:http, :get, url, _headers}
      assert url =~ "/messages?"
    end

    test "gmail/read parses headers, snippet and body", %{server: server} do
      assert {:disposition, :done, msg} = Server.call(server, "gmail/read", %{id: "m1"})

      assert msg.from == "Jane <jane@acme.com>"
      assert msg.subject == "Lunch?"
      assert msg.snippet =~ "lunch"
      assert msg.body =~ "Friday"
    end

    test "the OAuth token is woven into the bearer header trusted-side", %{server: server} do
      Server.call(server, "gmail/search", %{query: "x"})
      assert_received {:http, :get, _url, headers}
      assert {"Authorization", "Bearer test-token"} in headers
    end
  end

  describe "send is queued for human review, never sent directly" do
    test "calling gmail/send enqueues — the wire is NOT touched", %{server: server} do
      assert {:disposition, :queued, %{handle: handle}} =
               Server.call(server, "gmail/send", %{
                 to: "jane@acme.com",
                 subject: "Re: Lunch?",
                 body: "Friday works!"
               })

      assert handle == "eff_1"
      # nothing went out: no POST recorded
      refute_received {:http, :post, _url, _headers}
    end

    test "the operator sees the exact to/subject/body in the queue", %{server: server} do
      Server.call(server, "gmail/send", %{
        to: "jane@acme.com",
        subject: "Re: Lunch?",
        body: "Friday works!"
      })

      assert [{"eff_1", "gmail/send", args}] = Server.pending(server)
      assert args.to == "jane@acme.com"
      assert args.subject == "Re: Lunch?"
      assert args.body == "Friday works!"
    end

    test "approve releases it — the real send fires and returns the id", %{server: server} do
      {:disposition, :queued, %{handle: handle}} =
        Server.call(server, "gmail/send", %{to: "jane@acme.com", subject: "Hi", body: "Yo"})

      refute_received {:http, :post, _u, _h}

      assert {:disposition, :done, sent} = Server.approve(server, handle)
      assert sent.id == "sent123"
      assert sent.to == "jane@acme.com"

      # the POST really crossed the (fake) wire, only after approval
      assert_received {:http, :post, url, headers}
      assert url =~ "/messages/send"
      assert {"Authorization", "Bearer test-token"} in headers

      # and the queue no longer lists it as pending
      assert Server.pending(server) == []
    end

    test "deny rejects it — nothing is sent", %{server: server} do
      {:disposition, :queued, %{handle: handle}} =
        Server.call(server, "gmail/send", %{to: "jane@acme.com", subject: "Hi", body: "Yo"})

      assert {:disposition, :denied, %{reason: reason}} = Server.deny(server, handle)
      assert reason =~ "human"
      refute_received {:http, :post, _u, _h}
    end
  end

  describe "pure helpers" do
    test "build_raw produces a decodable RFC822 message" do
      raw = Gmail.build_raw("a@b.com", "Hello", "Body text")
      assert {:ok, decoded} = Base.url_decode64(raw, padding: false)
      assert decoded =~ "To: a@b.com"
      assert decoded =~ "Subject: Hello"
      assert decoded =~ "Body text"
    end

    test "parse_message tolerates a missing body" do
      msg = Gmail.parse_message(%{"id" => "x", "snippet" => "s", "payload" => %{"headers" => []}})
      assert msg.id == "x"
      assert msg.snippet == "s"
      assert msg.body == ""
    end
  end
end
