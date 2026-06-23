defmodule Substrate.JSONTest do
  @moduledoc """
  The hand-rolled OTP-only JSON used by the Anthropic client. Covers the shapes
  the client actually sees: a request body round-trips, and a realistic Messages
  response decodes — including escaped quotes, newlines, and `\\uXXXX`.
  """
  use ExUnit.Case, async: true

  alias Substrate.JSON

  test "round-trips the request shape" do
    body = %{
      "model" => "claude-opus-4-8",
      "max_tokens" => 4096,
      "system" => "line one\nline \"two\"",
      "messages" => [
        %{"role" => "user", "content" => "do the thing"},
        %{"role" => "assistant", "content" => "```lisp\n(describe)\n```"}
      ]
    }

    assert {:ok, ^body} = JSON.decode(JSON.encode(body))
  end

  test "decodes a Messages-API response, extracting text blocks" do
    # literal JSON: \n is an escaped newline, \" an escaped quote
    resp =
      "{\"id\":\"msg_1\",\"content\":[{\"type\":\"text\"," <>
        "\"text\":\"Let me\\n(describe)\\nwith a \\\"quote\\\"\"}]," <>
        "\"stop_reason\":\"end_turn\"}"

    assert {:ok, %{"content" => [block], "stop_reason" => "end_turn"}} = JSON.decode(resp)
    assert block["text"] == "Let me\n(describe)\nwith a \"quote\""
  end

  test "handles escapes and a \\u sequence" do
    assert {:ok, %{"s" => "tab\there / slash"}} = JSON.decode("{\"s\":\"tab\\there \\/ slash\"}")
    assert {:ok, %{"s" => "café"}} = JSON.decode("{\"s\":\"caf\\u00e9\"}")
  end

  test "numbers, booleans, null, and nesting" do
    json = "{\"n\":42,\"f\":1.5,\"neg\":-3,\"t\":true,\"f2\":false,\"z\":null,\"a\":[1,2,[3]]}"
    assert {:ok, m} = JSON.decode(json)
    assert m["n"] == 42
    assert m["f"] == 1.5
    assert m["neg"] == -3
    assert m["t"] == true and m["f2"] == false and m["z"] == nil
    assert m["a"] == [1, 2, [3]]
  end

  test "rejects malformed input" do
    assert {:error, _} = JSON.decode("{\"a\":}")
    assert {:error, _} = JSON.decode("{not json}")
    assert {:error, _} = JSON.decode("{\"a\":1} trailing")
  end

  test "encodes atom keys and values" do
    assert JSON.encode(%{role: :user}) == "{\"role\":\"user\"}"
  end
end
