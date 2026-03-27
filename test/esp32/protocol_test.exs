defmodule Esp32.ProtocolTest do
  use ExUnit.Case
  alias Esp32.Protocol

  test "calculate_checksum/1 returns XOR-based checksum with seed 0xEF" do
    # 0xEF ^ 0x01 ^ 0x02 = 0xEF ^ 0x03 = 0xEC
    assert Protocol.calculate_checksum(<<0x01, 0x02>>) == 0xEC
  end

  test "build_command/3 creates correct binary structure" do
    # Command SYNC (0x08), checksum 0x00, data <<0x01>>
    # Header: 0x00 (req), 0x08 (cmd), 0x01 0x00 (size 1), 0x00 0x00 0x00 0x00 (checksum)
    cmd = Protocol.build_command(:SYNC, 0, <<0x01>>)
    assert cmd == <<0x00, 0x08, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01>>
  end

  test "parse_response/1 parses correct response" do
    # Response SYNC (0x08), size 4, value 0x00, data <<0x01, 0x02, 0x03, 0x04>>
    resp = <<0x01, 0x08, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04>>
    assert Protocol.parse_response(resp) == {:ok, 0x08, 0, <<0x01, 0x02, 0x03, 0x04>>}
  end

  test "parse_status/1 extracts status and error" do
    # Data with 4 status bytes: status 0 (success), error 0
    data = <<0x01, 0x02, 0x00, 0x00, 0x00, 0x00>>
    assert Protocol.parse_status(data) == {:ok, <<0x01, 0x02>>}
  end

  test "parse_status/1 returns error on status 1" do
    # Data with 4 status bytes: status 1 (failure), error 7 (checksum error)
    data = <<0x01, 0x02, 0x01, 0x07, 0x00, 0x00>>
    assert Protocol.parse_status(data) == {:error, {1, 7}}
  end
end
