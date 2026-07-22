defmodule Substrate.Gmail do
  @moduledoc """
  L1 — the native Gmail edge. Full authority: it opens authenticated sockets to
  the Gmail REST API. It runs *inside* the trust boundary and is never nameable
  from L2 (the substrate's `bind` is stripped at the wall). The agent emits
  `(gmail/send :to … :subject … :body …)` as *intent*; the OAuth token is woven
  into the `Authorization` header by the membrane (`Substrate.Auth`) microseconds
  before the socket — the agent never sees, names, or can exfiltrate it.

  Three typed capabilities, deliberately not a generic HTTP hole:

    * `search/2` — `q` (Gmail search syntax) -> matching message ids + count.
    * `read/2`   — `id` -> the message's key headers + a plain-text body.
    * `send/2`   — `to`/`subject`/`body` -> builds the RFC 2822 message and the
      base64url `raw` payload **here, trusted-side**, then POSTs it. Because the
      capability is typed, a human reviewing the queued effect sees clean
      `to`/`subject`/`body` fields, not an opaque base64 blob.

  ## Why typed, and why send is gated by the substrate (not here)

  This module never decides policy — that's the membrane's job. `gmail.lisp`
  marks `gmail/send` with `(confirm-if always)`, so a send is *enqueued* for human
  review and only `execute/3`-d when an operator approves. Reads carry no
  `confirm-if`, so they run immediately. This file just performs whichever call
  the membrane has already cleared.

  ## Transport injection

  The HTTP call is read from the vault key `:__http__` (a 1-arity fun over a
  request map), falling back to a real `:httpc` client. Trusted-side only — the
  agent can neither read nor name it — it exists so the whole adjudicate →
  enqueue → approve → *send* path can be exercised offline with a fake transport.
  """

  alias Substrate.{JSON, Vault}

  @base "https://gmail.googleapis.com/gmail/v1/users/me"
  @timeout 15_000

  # --- capabilities (the membrane has already adjudicated by the time we run) ---

  def search(ctx, %{query: q}) when is_binary(q) do
    url = @base <> "/messages?maxResults=20&q=" <> URI.encode(q, &URI.char_unreserved?/1)

    with {:ok, %{"messages" => msgs}} <- get_json(ctx, url) do
      ids = msgs |> List.wrap() |> Enum.map(&Map.get(&1, "id")) |> Enum.reject(&is_nil/1)
      {:ok, %{ids: ids, count: length(ids), query: q}}
    else
      {:ok, %{}} -> {:ok, %{ids: [], count: 0, query: q}}
      {:error, _} = e -> e
    end
  end

  def search(_ctx, _args), do: {:error, :bad_request}

  @doc """
  Mailbox profile — address + total message/thread counts. Works under the
  restricted `gmail.metadata` scope (no `q`, no full bodies needed).
  """
  def profile(ctx, _args) do
    with {:ok, p} when is_map(p) <- get_json(ctx, @base <> "/profile") do
      {:ok,
       %{
         email: Map.get(p, "emailAddress"),
         messages_total: Map.get(p, "messagesTotal"),
         threads_total: Map.get(p, "threadsTotal")
       }}
    end
  end

  @doc """
  List the most recent message ids (no search query — metadata-scope safe).
  `count` caps how many ids come back; `estimate` is Gmail's whole-mailbox size.
  """
  def recent(ctx, %{count: n}) when is_integer(n) do
    url = @base <> "/messages?maxResults=" <> Integer.to_string(max(1, min(n, 500)))

    case get_json(ctx, url) do
      {:ok, %{"messages" => msgs} = resp} ->
        ids = msgs |> List.wrap() |> Enum.map(&Map.get(&1, "id")) |> Enum.reject(&is_nil/1)
        {:ok, %{ids: ids, count: length(ids), estimate: Map.get(resp, "resultSizeEstimate")}}

      {:ok, resp} ->
        {:ok, %{ids: [], count: 0, estimate: Map.get(resp, "resultSizeEstimate", 0)}}

      {:error, _} = e ->
        e
    end
  end

  def recent(_ctx, _args), do: {:error, :bad_request}

  @doc """
  Read just a message's headers (From/To/Subject/Date) + snippet via the
  `format=metadata` projection — the read that works under `gmail.metadata`.
  """
  def headers(ctx, %{id: id}) when is_binary(id) do
    url =
      @base <>
        "/messages/" <>
        URI.encode(id, &URI.char_unreserved?/1) <>
        "?format=metadata&metadataHeaders=From&metadataHeaders=To" <>
        "&metadataHeaders=Subject&metadataHeaders=Date"

    with {:ok, msg} when is_map(msg) <- get_json(ctx, url) do
      {:ok, parse_message(msg)}
    end
  end

  def headers(_ctx, _args), do: {:error, :bad_request}

  def read(ctx, %{id: id}) when is_binary(id) do
    url = @base <> "/messages/" <> URI.encode(id, &URI.char_unreserved?/1) <> "?format=full"

    with {:ok, msg} when is_map(msg) <- get_json(ctx, url) do
      {:ok, parse_message(msg)}
    end
  end

  def read(_ctx, _args), do: {:error, :bad_request}

  def send(ctx, %{to: to, subject: subject, body: body})
      when is_binary(to) and is_binary(subject) and is_binary(body) do
    raw = build_raw(to, subject, body)
    payload = JSON.encode(%{"raw" => raw})

    with {:ok, %{"id" => id} = resp} <- post_json(ctx, @base <> "/messages/send", payload) do
      {:ok, %{id: id, thread_id: Map.get(resp, "threadId"), to: to, subject: subject}}
    else
      {:ok, other} -> {:error, "unexpected send response: #{inspect(other)}"}
      {:error, _} = e -> e
    end
  end

  def send(_ctx, _args), do: {:error, :bad_request}

  # --- pure helpers (unit-tested with no network) ---

  @doc """
  Build the base64url-encoded RFC 2822 message Gmail's `messages.send` expects in
  its `raw` field. Headers are CRLF-separated; the subject is left as-is (callers
  pass plain ASCII subjects in the slice).
  """
  def build_raw(to, subject, body) do
    ("To: #{to}\r\n" <>
       "Subject: #{subject}\r\n" <>
       "Content-Type: text/plain; charset=UTF-8\r\n" <>
       "\r\n" <>
       body)
    |> b64url()
  end

  @doc "URL-safe base64 with no padding — the encoding Gmail's `raw` field uses."
  def b64url(bin), do: Base.url_encode64(bin, padding: false)

  @doc """
  Reduce a full Gmail message resource to the fields an agent reasons over: the
  From/Subject/Date headers, the snippet, and a best-effort plain-text body.
  """
  def parse_message(%{} = msg) do
    headers = header_map(get_in(msg, ["payload", "headers"]) || [])

    %{
      id: Map.get(msg, "id"),
      thread_id: Map.get(msg, "threadId"),
      from: Map.get(headers, "from"),
      to: Map.get(headers, "to"),
      subject: Map.get(headers, "subject"),
      date: Map.get(headers, "date"),
      snippet: Map.get(msg, "snippet", ""),
      body: extract_body(Map.get(msg, "payload", %{}))
    }
  end

  defp header_map(headers) do
    Map.new(headers, fn h -> {String.downcase(Map.get(h, "name", "")), Map.get(h, "value")} end)
  end

  # Prefer a text/plain part's body; walk multipart payloads; fall back to "".
  defp extract_body(%{"mimeType" => "text/plain", "body" => %{"data" => data}}), do: decode_part(data)

  defp extract_body(%{"parts" => parts}) when is_list(parts) do
    Enum.find_value(parts, "", fn part ->
      case extract_body(part) do
        "" -> nil
        text -> text
      end
    end)
  end

  defp extract_body(%{"body" => %{"data" => data}}), do: decode_part(data)
  defp extract_body(_), do: ""

  defp decode_part(data) do
    case Base.url_decode64(data, padding: false) do
      {:ok, bin} -> bin
      :error -> ""
    end
  end

  # --- HTTP plumbing (auth headers injected by the membrane via ctx) ---

  defp get_json(ctx, url) do
    case transport(ctx).(%{method: :get, url: url, headers: auth(ctx), body: nil}) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> JSON.decode(body)
      {:ok, %{status: status, body: body}} -> {:error, api_error(status, body)}
      {:error, reason} -> {:error, "transport: #{inspect(reason)}"}
    end
  end

  defp post_json(ctx, url, payload) do
    headers = [{"Content-Type", "application/json"} | auth(ctx)]

    case transport(ctx).(%{method: :post, url: url, headers: headers, body: payload}) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> JSON.decode(body)
      {:ok, %{status: status, body: body}} -> {:error, api_error(status, body)}
      {:error, reason} -> {:error, "transport: #{inspect(reason)}"}
    end
  end

  # The auth headers the membrane resolved from the vault for this call.
  defp auth(ctx), do: Vault.fetch(ctx, :__auth_headers__, [])

  # Injectable transport; defaults to the real httpc client below.
  defp transport(ctx), do: Vault.fetch(ctx, :__http__, &httpc_transport/1)

  defp api_error(status, body) do
    case JSON.decode(body) do
      {:ok, %{"error" => %{"message" => m}}} -> "Gmail #{status}: #{m}"
      _ -> "Gmail #{status}: #{String.slice(to_string(body), 0, 300)}"
    end
  end

  # --- the real edge ---

  defp httpc_transport(%{method: :get, url: url, headers: headers}) do
    request = {to_charlist(url), charlist_headers(headers)}
    do_request(:get, request)
  end

  defp httpc_transport(%{method: :post, url: url, headers: headers, body: body}) do
    {ctype, rest} = pop_content_type(headers)
    request = {to_charlist(url), charlist_headers(rest), to_charlist(ctype), body}
    do_request(:post, request)
  end

  defp do_request(method, request) do
    http_opts = [timeout: @timeout, connect_timeout: @timeout, ssl: [verify: :verify_none]]

    case :httpc.request(method, request, http_opts, body_format: :binary) do
      {:ok, {{_proto, status, _reason}, _h, body}} -> {:ok, %{status: status, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp pop_content_type(headers) do
    {ct, rest} =
      Enum.split_with(headers, fn {k, _} -> String.downcase(k) == "content-type" end)

    ctype = case ct do
      [{_, v} | _] -> v
      [] -> "application/json"
    end

    {ctype, rest}
  end

  defp charlist_headers(headers),
    do: Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
end
