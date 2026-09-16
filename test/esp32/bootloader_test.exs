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
end
