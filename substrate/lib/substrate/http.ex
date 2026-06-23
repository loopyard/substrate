defmodule Substrate.HTTP do
  @moduledoc """
  L1 — the native HTTP(S) client. Full authority: it actually opens sockets to
  the outside world. It runs *inside* the trust boundary and is never nameable
  from L2 (the substrate's `bind` is stripped at the wall).

  One edge, the full verb set: `get/2`, `post/2`, `put/2`, `patch/2`, `delete/2`.
  GET/DELETE carry no body; the write verbs take `:body` — a substrate map (which
  is JSON-encoded for you) or a pre-formed string. Bodies go out as
  `application/json` (the dominant API case); the param model has no optional
  params, so the content type is not an agent-facing knob in this PoC.

  Responses always carry `status`, `body`, `bytes`, `url`; when the body parses
  as JSON, a decoded `json` field is attached too (string-keyed maps — never
  atoms, so an untrusted response can't grow the atom table). That `json` field
  is the agent's way to *use* an API result without a separate parse step.

  The membrane already refused any host not on the allowlist before this code
  runs (`deny-if host-denied`). This re-checks the host against the vault
  allowlist anyway — defense in depth, exactly like `Substrate.FS` re-resolving
  the jail behind `deny-if escapes-jail`. The allowlist lives in the L0 vault;
  the agent can neither read it nor name a host outside it. Auth headers are
  resolved from the vault by the membrane and handed to us in the ctx — we attach
  them and never see the secret's source.

  Returns `{:ok, payload_map}` or `{:error, reason}`. A transport failure (DNS,
  timeout, refused) rode a *permitted* effect, so it comes back under `:done`
  with an `:error` key — same convention as a missing file in `FS.read`. A host
  that isn't allowed returns `{:error, ...}`, which the membrane maps to
  `:denied`.

  PoC note: TLS is `verify_none` here — a real deployment would pin a CA trust
  store. The point under test is the *capability wall and allowlist*, not the
  transport's cert chain.
  """

  alias Substrate.{JSON, Vault}

  @timeout 8_000
  @max_bytes 5_000_000
  @json_ct "application/json"

  def get(ctx, args), do: dispatch(:get, ctx, args)
  def post(ctx, args), do: dispatch(:post, ctx, args)
  def put(ctx, args), do: dispatch(:put, ctx, args)
  def patch(ctx, args), do: dispatch(:patch, ctx, args)
  def delete(ctx, args), do: dispatch(:delete, ctx, args)

  defp dispatch(method, ctx, %{url: url} = args) when is_binary(url) do
    with :ok <- allowed_host(ctx, url) do
      headers = Vault.fetch(ctx, :__auth_headers__, [])
      request(method, url, headers, encode_body(Map.get(args, :body)))
    end
  end

  defp dispatch(_method, _ctx, _args), do: {:error, :bad_request}

  # body: a map -> JSON, a string -> as-is, absent -> none. nil means no body.
  defp encode_body(nil), do: nil
  defp encode_body(map) when is_map(map), do: JSON.encode(map)
  defp encode_body(str) when is_binary(str), do: str

  # the allowlist — named here and nowhere the agent can see
  defp allowed_host(ctx, url) do
    allow = Vault.fetch(ctx, :http_allow, [])

    case URI.parse(url).host do
      host when is_binary(host) and host != "" ->
        if host in allow, do: :ok, else: {:error, :host_not_allowed}

      _ ->
        {:error, :bad_url}
    end
  end

  defp request(method, url, headers, body) do
    http_opts = [timeout: @timeout, connect_timeout: @timeout, ssl: [verify: :verify_none]]
    opts = [body_format: :binary]
    hdrs = Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    req =
      if body do
        {to_charlist(url), hdrs, to_charlist(@json_ct), body}
      else
        {to_charlist(url), hdrs}
      end

    case :httpc.request(method, req, http_opts, opts) do
      {:ok, {{_proto, status, _reason}, _headers, resp_body}} ->
        resp_body = clamp(resp_body)
        base = %{status: status, body: resp_body, bytes: byte_size(resp_body), url: url}
        {:ok, attach_json(base, resp_body)}

      {:error, reason} ->
        {:ok, %{status: 0, error: inspect(reason), body: "", bytes: 0, url: url}}
    end
  end

  # decode-if-JSON: a parseable body gets a string-keyed `json` field; anything
  # else is left as the raw `body` string. Never raises — non-JSON just opts out.
  defp attach_json(payload, ""), do: payload

  defp attach_json(payload, body) do
    case JSON.decode(body) do
      {:ok, term} -> Map.put(payload, :json, term)
      {:error, _} -> payload
    end
  end

  defp clamp(body) when byte_size(body) > @max_bytes, do: binary_part(body, 0, @max_bytes)
  defp clamp(body), do: body
end
