defmodule AhoyTest do
  use ExUnit.Case
  doctest Ahoy

  test "greets the world" do
    assert Ahoy.hello() == :world
  end
end
