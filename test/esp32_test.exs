defmodule Esp32Test do
  use ExUnit.Case
  doctest Esp32

  test "greets the world" do
    assert Esp32.hello() == :world
  end
end
