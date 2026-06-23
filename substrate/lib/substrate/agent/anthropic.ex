defmodule Substrate.Agent.Anthropic do
  @moduledoc """
  The real model behind `Substrate.Agent` — a thin Claude (Messages API) client
  built on OTP's `:httpc` and `Substrate.JSON`, so the substrate keeps its
  no-external-deps property even when an LLM is driving it.

  `model/1` returns the 2-arity fun the agent loop expects
  (`(system, messages) -> {:ok, text} | {:error, reason}`). The agent emits and
  reacts to *plain text* (the CodeAct protocol — programs live in fenced blocks),
  so we never touch Anthropic's tool-use wire format; the request is just a
  system string plus the running message list.

  Config (all overridable via `opts`):

    * `:api_key`    — defaults to the `ANTHROPIC_API_KEY` env var
    * `:model`      — defaults to `"claude-opus-4-8"`
    * `:max_tokens` — defaults to `4096`

  PoC note: TLS is `verify_none` here, matching `Substrate.HTTP` — the point
  under test is the capability wall, not the transport's cert chain.
  """

  alias Substrate.JSON

  @endpoint ~c"https://api.anthropic.com/v1/messages"
  @version ~c"2023-06-01"
  @default_model "claude-opus-4-8"
  @default_max_tokens 4096
  @timeout 120_000

  @doc """
  Build the model fun for `Substrate.Agent.run/4`. Raises if no API key is set
  (neither in `opts` nor in `ANTHROPIC_API_KEY`).
  """
  def model(opts \\ []) do
    key = Keyword.get(opts, :api_key) || System.get_env("ANTHROPIC_API_KEY") || raise_no_key()
    model_id = Keyword.get(opts, :model, @default_model)
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)

    fn system, messages -> chat(key, model_id, max_tokens, system, messages) end
  end

  defp chat(key, model_id, max_tokens, system, messages) do
    body =
      JSON.encode(%{
        "model" => model_id,
        "max_tokens" => max_tokens,
        "system" => system,
        "messages" => Enum.map(messages, fn %{role: r, content: c} -> %{"role" => r, "content" => c} end)
      })

    headers = [{~c"x-api-key", to_charlist(key)}, {~c"anthropic-version", @version}]
    http_opts = [timeout: @timeout, connect_timeout: @timeout, ssl: [verify: :verify_none]]
    request = {@endpoint, headers, ~c"application/json", body}

    case :httpc.request(:post, request, http_opts, body_format: :binary) do
      {:ok, {{_proto, 200, _}, _headers, resp}} -> extract_text(resp)
      {:ok, {{_proto, status, _}, _headers, resp}} -> {:error, "HTTP #{status}: #{api_error(resp)}"}
      {:error, reason} -> {:error, "transport: #{inspect(reason)}"}
    end
  end

  # Pull and concatenate the text blocks from a Messages response.
  defp extract_text(resp) do
    case JSON.decode(resp) do
      {:ok, %{"content" => blocks}} when is_list(blocks) ->
        text =
          blocks
          |> Enum.filter(&(is_map(&1) and &1["type"] == "text"))
          |> Enum.map_join("", & &1["text"])

        {:ok, text}

      {:ok, other} ->
        {:error, "unexpected response shape: #{inspect(other)}"}

      {:error, reason} ->
        {:error, "could not parse response: #{reason}"}
    end
  end

  # Surface Anthropic's `{"error": {"message": ...}}` body when present.
  defp api_error(resp) do
    case JSON.decode(resp) do
      {:ok, %{"error" => %{"message" => m}}} -> m
      _ -> String.slice(resp, 0, 400)
    end
  end

  defp raise_no_key do
    raise """
    No Anthropic API key. Set ANTHROPIC_API_KEY in the environment, e.g.

        ANTHROPIC_API_KEY=sk-ant-... mix substrate.agent <substrate.lisp> --goal "..."
    """
  end
end
