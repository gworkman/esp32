defmodule Esp32.BootloaderTest do
  use ExUnit.Case, async: true
  alias Esp32.{Bootloader, Device, FakeUART}
  import Esp32.FakeUART, only: [response: 2, response: 3]

  defp device(handler, attrs \\ []) do
    {:ok, uart} = FakeUART.start_link(handler)
    struct!(%Device{uart: uart, chip: :esp32c3, stub?: true, baud: 115_200}, attrs)
  end

  describe "command/4" do
    test "returns value and data of a successful response" do
      device =
        device(fn {0x0A, <<0x40001000::little-32>>} ->
          [response(:read_reg, <<0, 0>>, 0x1234)]
        end)

      assert {:ok, 0x1234, <<>>} =
               Bootloader.command(device, :read_reg, <<0x40001000::little-32>>)
    end

    test "skips echoes, garbage, stale responses and error frames" do
      device =
        device(fn {0x0A, _} ->
          [
            <<0x00, 0x0A, 4::little-16, 0::little-32, 0, 0, 0, 0>>,
            "boot",
            {:error, :invalid_escape},
            response(:sync, <<0, 0>>, 0x55),
            response(:read_reg, <<0, 0>>, 42)
          ]
        end)

      assert {:ok, 42, <<>>} = Bootloader.command(device, :read_reg, <<0::little-32>>)
    end

    test "reports the error byte of a failed response" do
      device = device(fn {0x0A, _} -> [response(:read_reg, <<1, 5, 0, 0>>)] end, stub?: false)
      assert {:error, {:read_reg, 5}} = Bootloader.command(device, :read_reg, <<0::little-32>>)
    end

    test "times out when no matching response arrives" do
      device = device(fn _ -> [response(:sync, <<0, 0>>)] end)
      assert {:error, :timeout} = Bootloader.command(device, :read_reg, <<0::little-32>>)
    end

    test "returns resp_data_len bytes of data" do
      device = device(fn {0x13, _} -> [response(:spi_flash_md5, <<1, 2, 3, 0, 0>>)] end)

      assert {:ok, _, <<1, 2, 3>>} =
               Bootloader.command(device, :spi_flash_md5, <<>>, resp_data_len: 3)
    end

    test "sends the checksum in the packet header" do
      device = device(fn {0x03, _} -> [response(:flash_data, <<0, 0>>)] end)
      assert {:ok, _, _} = Bootloader.command(device, :flash_data, <<9>>, checksum: 0xE6)
      assert [{0x03, <<9>>}] = FakeUART.writes(device.uart)
    end

    test "gives up after 100 unmatched frames" do
      device = device(fn _ -> List.duplicate(response(:sync, <<0, 0>>), 101) end)
      assert {:error, :no_response} = Bootloader.command(device, :read_reg, <<0::little-32>>)
    end
  end

  test "read_reg/2 and write_reg/3" do
    device =
      device(fn
        {0x0A, <<0x10::little-32>>} ->
          [response(:read_reg, <<0, 0>>, 7)]

        {0x09, <<0x10::little-32, 7::little-32, 0xFFFFFFFF::little-32, 0::little-32>>} ->
          [response(:write_reg, <<0, 0>>)]
      end)

    assert {:ok, 7} = Bootloader.read_reg(device, 0x10)
    assert :ok = Bootloader.write_reg(device, 0x10, 7)
  end

  test "chunk/2 splits a binary into blocks" do
    assert Bootloader.chunk(<<1, 2, 3, 4, 5>>, 2) == [<<1, 2>>, <<3, 4>>, <<5>>]
    assert Bootloader.chunk(<<>>, 2) == []
  end

  @sync_payload <<0x07, 0x07, 0x12, 0x20>> <> :binary.copy(<<0x55>>, 32)

  describe "sync/1" do
    test "consumes all eight replies and detects the ROM loader" do
      device =
        device(fn {0x08, @sync_payload} ->
          List.duplicate(response(:sync, <<0, 0, 0, 0>>, 0x80), 8)
        end)

      assert {:ok, false} = Bootloader.sync(device)
      assert {:error, :timeout} = Bootloader.read_response(device, nil, 10)
    end

    test "detects a running stub when every reply value is zero" do
      device = device(fn {0x08, _} -> List.duplicate(response(:sync, <<0, 0>>, 0), 8) end)
      assert {:ok, true} = Bootloader.sync(device)
    end

    test "fails when fewer than eight replies arrive" do
      device = device(fn {0x08, _} -> List.duplicate(response(:sync, <<0, 0>>, 0), 3) end)
      assert {:error, :timeout} = Bootloader.sync(device)
    end

    test "ignores status bytes in the replies" do
      device =
        device(fn {0x08, _} -> List.duplicate(response(:sync, <<1, 5, 0, 0>>, 0x80), 8) end)

      assert {:ok, false} = Bootloader.sync(device)
    end
  end

  # 20-byte security info block (flags, crypt count, 7 key purposes, chip id, api version)
  defp security_info(chip_id) do
    <<0::little-32, 0, 0::56, chip_id::little-32, 1::little-32>>
  end

  describe "get_security_info/1" do
    test "parses the 20-byte block" do
      device =
        device(fn {0x14, <<>>} ->
          [response(:get_security_info, security_info(9) <> <<0, 0, 0, 0>>)]
        end)

      assert {:ok, %{chip_id: 9, api_version: 1, flash_crypt_cnt: 0}} =
               Bootloader.get_security_info(device)
    end

    test "parses the 12-byte block without a chip id (ESP32-S2)" do
      device =
        device(fn {0x14, <<>>} ->
          [response(:get_security_info, <<4::little-32, 0, 0::56, 0, 0, 0, 0>>)]
        end)

      assert {:ok, %{chip_id: nil, flags: 4}} = Bootloader.get_security_info(device)
    end

    test "reports unsupported command" do
      device = device(fn {0x14, <<>>} -> [response(:get_security_info, <<1, 5, 0, 0>>)] end)
      assert {:error, {:get_security_info, 5}} = Bootloader.get_security_info(device)
    end
  end

  describe "detect_chip/1" do
    test "uses the security-info chip id" do
      device =
        device(fn {0x14, _} -> [response(:get_security_info, security_info(13) <> <<0, 0>>)] end)

      assert {:ok, :esp32c6} = Bootloader.detect_chip(device)
    end

    test "falls back to the magic register past the ROM's eight error replies" do
      device =
        device(fn
          {0x14, _} -> List.duplicate(response(:get_security_info, <<1, 5, 0, 0>>), 8)
          {0x0A, <<0x40001000::little-32>>} -> [response(:read_reg, <<0, 0, 0, 0>>, 0x00F01D83)]
        end)

      assert {:ok, :esp32} = Bootloader.detect_chip(device)
    end

    test "falls back to the magic register when the chip id is absent" do
      device =
        device(fn
          {0x14, _} -> [response(:get_security_info, <<0::little-32, 0, 0::56, 0, 0, 0, 0>>)]
          {0x0A, _} -> [response(:read_reg, <<0, 0, 0, 0>>, 0x000007C6)]
        end)

      assert {:ok, :esp32s2} = Bootloader.detect_chip(device)
    end

    test "reports unknown ids and magics" do
      device =
        device(fn {0x14, _} -> [response(:get_security_info, security_info(99) <> <<0, 0>>)] end)

      assert {:error, {:unknown_chip_id, 99}} = Bootloader.detect_chip(device)

      device =
        device(fn
          {0x14, _} -> [response(:get_security_info, <<1, 5, 0, 0>>)]
          {0x0A, _} -> [response(:read_reg, <<0, 0, 0, 0>>, 0x12345678)]
        end)

      assert {:error, {:unknown_chip_magic, 0x12345678}} = Bootloader.detect_chip(device)
    end
  end
end
