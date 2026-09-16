defmodule Esp32.SLIPTest do
  use ExUnit.Case, async: true
  alias Esp32.SLIP

  test "encode/1 frames data with 0xC0" do
    assert SLIP.encode(<<0x01, 0x02>>) == <<0xC0, 0x01, 0x02, 0xC0>>
  end

  test "encode/1 escapes 0xC0 and 0xDB" do
    assert SLIP.encode(<<0xC0, 0xDB>>) == <<0xC0, 0xDB, 0xDC, 0xDB, 0xDD, 0xC0>>
  end

  test "decode/1 unescapes a frame body" do
    assert SLIP.decode(<<0x01, 0xDB, 0xDC, 0xDB, 0xDD, 0x02>>) ==
             {:ok, <<0x01, 0xC0, 0xDB, 0x02>>}
  end

  test "decode/1 returns error on invalid escape" do
    assert SLIP.decode(<<0xDB, 0x00>>) == {:error, :invalid_escape}
  end

  describe "framing" do
    setup do
      {:ok, state} = SLIP.init([])
      %{state: state}
    end

    test "add_framing/2 SLIP-encodes", %{state: state} do
      assert {:ok, <<0xC0, 0x01, 0xDB, 0xDC, 0xC0>>, ^state} =
               SLIP.add_framing(<<0x01, 0xC0>>, state)
    end

    test "yields every complete frame in one chunk", %{state: state} do
      data = <<0xC0, 1, 2, 0xC0, 0xC0, 3, 0xC0>>
      assert {:ok, [<<1, 2>>, <<3>>], nil} = SLIP.remove_framing(data, state)
    end

    test "keeps partial frames across chunks, including split escapes", %{state: state} do
      assert {:in_frame, [], s1} = SLIP.remove_framing(<<0xC0, 1, 0xDB>>, state)
      assert {:ok, [<<1, 0xC0, 2>>], nil} = SLIP.remove_framing(<<0xDC, 2, 0xC0>>, s1)
    end

    test "discards garbage before a frame and empty frames", %{state: state} do
      data = <<"boot log", 0xC0, 0xC0, 0xC0, 9, 0xC0, "noise">>
      assert {:ok, [<<9>>], nil} = SLIP.remove_framing(data, state)
    end

    test "reports invalid escapes as error frames", %{state: state} do
      assert {:ok, [{:error, :invalid_escape}], nil} =
               SLIP.remove_framing(<<0xC0, 0xDB, 0, 0xC0>>, state)
    end

    test "flush/2 and frame_timeout/1 drop partial frames", %{state: state} do
      {:in_frame, [], s1} = SLIP.remove_framing(<<0xC0, 1>>, state)
      assert SLIP.flush(:receive, s1) == nil
      assert SLIP.frame_timeout(s1) == {:ok, [], nil}
    end
  end
end
