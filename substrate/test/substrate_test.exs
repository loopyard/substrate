defmodule SubstrateTest do
  use ExUnit.Case
  doctest Substrate

  test "greets the world" do
    assert Substrate.hello() == :world
  end
end
