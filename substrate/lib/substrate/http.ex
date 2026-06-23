defmodule Substrate.HTTP do
  @moduledoc """
  L1 — the native HTTP(S) client. Full authority: it actually opens sockets to
  the outside world. It runs *inside* the trust boundary and is never nameable
  from L2 (the substrate's `bind` is stripped at the wall).

  The membrane already refused any host not on the allowlist before this code
  runs (`deny-if host-denied`). This re-checks the host against the vault
  allowlist anyway — defense in depth, exactly like `Substrate.FS` re-resolving
  the jail behind `deny-if escapes-jail`. The allowlist lives in the L0 vault;
  the agent can neither read it nor name a host outside it.

  Returns `{:ok, payload_map}` or `{:error, reason}`. A transport failure (DNS,
  timeout, refused) rode a *permitted* effect, so it comes back under `:done`
  with an `:error` key — same convention as a missing file in `FS.read`. A host
  that isn't allowed returns `{:error, ...}`, which the membrane maps to
  `:denied`.

  PoC note: TLS is `verify_none` here — a real deployment would pin a CA trust
  store. The point under test is the *capability wall and allowlist*, not the
  transport's cert chain.
  """

  alias Substrate.Vault

  @timeout 8_000
  @max_bytes 5_000_000

  def get(ctx, %{url: url}) when is_binary(url) do
    with :ok <- allowed_host(ctx, url) do
      # Auth headers were resolved from the vault by the membrane and handed to
      # us in the ctx. We just attach them — we never see the secret's source.
      request(url, Vault.fetch(ctx, :__auth_headers__, []))
    end
  end

  def get(_ctx, _args), do: {:error, :bad_request}

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

  defp request(url, headers) do
    http_opts = [timeout: @timeout, connect_timeout: @timeout, ssl: [verify: :verify_none]]
    opts = [body_format: :binary]
    hdrs = Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    case :httpc.request(:get, {to_charlist(url), hdrs}, http_opts, opts) do
      {:ok, {{_proto, status, _reason}, _headers, body}} ->
        body = clamp(body)
        {:ok, %{status: status, body: body, bytes: byte_size(body), url: url}}

      {:error, reason} ->
        {:ok, %{status: 0, error: inspect(reason), body: "", bytes: 0, url: url}}
    end
  end

  defp clamp(body) when byte_size(body) > @max_bytes, do: binary_part(body, 0, @max_bytes)
  defp clamp(body), do: body
end
