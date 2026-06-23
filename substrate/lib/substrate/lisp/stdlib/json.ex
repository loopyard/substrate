defmodule Substrate.Lisp.Stdlib.Json do
  @moduledoc """
  Stdlib group: JSON. Pure computation, no authority — it belongs in front of the
  wall, not behind it. `parse-json` yields string-keyed maps (read with
  `(get m "field")`); a bad string is `nil`, not a fault, so the agent can branch.
  """
  alias Substrate.JSON

  def names, do: ~w(parse-json to-json)

  def call("parse-json", [s], _ap) when is_binary(s) do
    case JSON.decode(s) do
      {:ok, term} -> term
      {:error, _} -> nil
    end
  end

  def call("to-json", [term], _ap), do: JSON.encode(term)
end
