defmodule Substrate.Lisp.Stdlib.String do
  @moduledoc "Stdlib group: strings. `string` concatenates any displayed values."
  alias Substrate.Show

  def namespace, do: "string"
  def names, do: ~w(string join split uppercase lowercase starts-with? ends-with?)

  def call("string", args, _ap), do: Enum.map_join(args, "", &Show.display/1)
  def call("join", [coll, sep], _ap), do: Enum.map_join(coll, sep, &Show.display/1)
  def call("split", [s, sep], _ap) when is_binary(s) and is_binary(sep), do: String.split(s, sep)
  def call("uppercase", [s], _ap) when is_binary(s), do: String.upcase(s)
  def call("lowercase", [s], _ap) when is_binary(s), do: String.downcase(s)
  def call("starts-with?", [s, p], _ap) when is_binary(s), do: String.starts_with?(s, p)
  def call("ends-with?", [s, p], _ap) when is_binary(s), do: String.ends_with?(s, p)
end
