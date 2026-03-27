defmodule Esp32.SLIPTest do
  use ExUnit.Case
  alias Esp32.SLIP

  test "encode/1 frames data with 0xC0" do
    assert SLIP.encode(<<0x01, 0x02>>) == <<0xC0, 0x01, 0x02, 0xC0>>
  end

  test "encode/1 escapes 0xC0 and 0xDB" do
    assert SLIP.encode(<<0xC0, 0xDB>>) == <<0xC0, 0xDB, 0xDC, 0xDB, 0xDD, 0xC0>>
  end

  test "decode/1 unescapes data and removes framing" do
    encoded = <<0xC0, 0x01, 0xDB, 0xDC, 0xDB, 0xDD, 0x02, 0xC0>>
    assert SLIP.decode(encoded) == {:ok, <<0x01, 0xC0, 0xDB, 0x02>>}
  end

  test "decode/1 handles packets without explicit 0xC0 framing" do
    assert SLIP.decode(<<0x01, 0x02>>) == {:ok, <<0x01, 0x02>>}
  end

  test "decode/1 returns error on invalid escape" do
    assert SLIP.decode(<<0xDB, 0x00>>) == {:error, :invalid_escape}
  end
end
