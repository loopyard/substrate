defmodule Substrate.Lisp.Stdlib.Str do
  @moduledoc "Stdlib group: strings. `str` concatenates any displayed values."
  alias Substrate.Show

  def namespace, do: "str"
  def names, do: ~w(str join split upcase downcase starts-with? ends-with?)

  def call("str", args, _ap), do: Enum.map_join(args, "", &Show.display/1)
  def call("join", [coll, sep], _ap), do: Enum.map_join(coll, sep, &Show.display/1)
  def call("split", [s, sep], _ap) when is_binary(s) and is_binary(sep), do: String.split(s, sep)
  def call("upcase", [s], _ap) when is_binary(s), do: String.upcase(s)
  def call("downcase", [s], _ap) when is_binary(s), do: String.downcase(s)
  def call("starts-with?", [s, p], _ap) when is_binary(s), do: String.starts_with?(s, p)
  def call("ends-with?", [s, p], _ap) when is_binary(s), do: String.ends_with?(s, p)
end
