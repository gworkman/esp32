defmodule Esp32.ProtocolTest do
  use ExUnit.Case, async: true
  alias Esp32.Protocol

  test "checksum/1 XORs bytes with seed 0xEF" do
    assert Protocol.checksum(<<>>) == 0xEF
    assert Protocol.checksum(<<0x01, 0x02>>) == 0xEC
  end

  test "command_id/1 and command_name/1" do
    assert Protocol.command_id(:sync) == 0x08
    assert Protocol.command_name(0x0A) == :read_reg
    assert Protocol.command_name(0xFF) == nil
  end

  test "build_command/3 builds a request packet" do
    assert Protocol.build_command(:sync, 0, <<0x01>>) == <<0x00, 0x08, 1, 0, 0, 0, 0, 0, 0x01>>
  end

  test "parse_response/1" do
    assert Protocol.parse_response(<<0x01, 0x08, 4::little-16, 7::little-32, 1, 2, 3, 4>>) ==
             {:ok, 0x08, 7, <<1, 2, 3, 4>>}

    assert Protocol.parse_response(<<0x00, 0x08, 0::little-16, 0::little-32>>) == :error
    assert Protocol.parse_response(<<0x01, 0x08, 9::little-16, 0::little-32, 1>>) == :error
    assert Protocol.parse_response({:error, :invalid_escape}) == :error
  end

  describe "check_status/2" do
    test "stub responses carry two status bytes" do
      assert Protocol.check_status(<<0, 0>>, 0) == {:ok, <<>>}
      assert Protocol.check_status(<<1, 7>>, 0) == {:error, {:status, 7}}
    end

    test "ROM responses carry two extra reserved bytes that are ignored" do
      assert Protocol.check_status(<<0, 0, 0, 0>>, 0) == {:ok, <<>>}
      assert Protocol.check_status(<<1, 5, 0, 0>>, 0) == {:error, {:status, 5}}
    end

    test "status follows resp_data_len bytes of data" do
      assert Protocol.check_status(<<1, 2, 0, 0>>, 2) == {:ok, <<1, 2>>}
      assert Protocol.check_status(<<1, 2, 0, 0, 0, 0>>, 2) == {:ok, <<1, 2>>}
      assert Protocol.check_status(<<1, 2, 1, 9>>, 2) == {:error, {:status, 9}}
    end

    test "short responses report their leading status or :short_response" do
      assert Protocol.check_status(<<1, 5, 0, 0>>, 20) == {:error, {:status, 5}}
      assert Protocol.check_status(<<0, 0>>, 20) == {:error, :short_response}
      assert Protocol.check_status(<<>>, 0) == {:error, :short_response}
    end
  end
end
