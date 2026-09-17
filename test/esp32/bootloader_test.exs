defmodule Esp32.BootloaderTest do
  use ExUnit.Case, async: true
  alias Esp32.{Bootloader, Device, FakeUART}
  import Esp32.FakeUART, only: [response: 2, response: 3]
  import Bitwise

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

  describe "mem_end/2" do
    test "ignores a missing reply from the ROM loader" do
      device = device(fn _ -> [] end, stub?: false)
      assert :ok = Bootloader.mem_end(device, 0x4000)
      assert [{0x06, <<0::little-32, 0x4000::little-32>>}] = FakeUART.writes(device.uart)
    end

    test "propagates errors from the stub" do
      device = device(fn _ -> [] end, stub?: true)
      assert {:error, :timeout} = Bootloader.mem_end(device, 0x4000)
    end
  end

  defp stub_handler do
    fn
      {0x05, _} -> [response(:mem_begin, <<0, 0, 0, 0>>)]
      {0x07, _} -> [response(:mem_data, <<0, 0, 0, 0>>)]
      {0x06, _} -> [response(:mem_end, <<0, 0, 0, 0>>), "OHAI"]
    end
  end

  describe "load_stub/1" do
    test "uploads text and data segments then waits for OHAI" do
      device = device(stub_handler(), chip: :esp32c3, stub?: false)
      assert {:ok, %Device{stub?: true}} = Bootloader.load_stub(device)

      stub =
        Application.app_dir(:esp32, "priv/stubs/esp32c3.json") |> File.read!() |> Jason.decode!()

      text = Base.decode64!(stub["text"])
      writes = FakeUART.writes(device.uart)

      assert {0x05,
              <<_size::little-32, blocks::little-32, 0x1800::little-32, text_start::little-32>>} =
               hd(writes)

      assert blocks == div(byte_size(text) + 0x17FF, 0x1800)
      assert text_start == stub["text_start"]
      assert Enum.count(writes, &match?({0x05, _}, &1)) == 2
      assert {0x06, <<0::little-32, entry::little-32>>} = List.last(writes)
      assert entry == stub["entry"]
    end

    test "uses 0x800 blocks over USB-OTG" do
      device = device(stub_handler(), chip: :esp32s3, stub?: false, usb_otg?: true)
      assert {:ok, _} = Bootloader.load_stub(device)

      assert {0x05, <<_::little-32, _::little-32, 0x800::little-32, _::little-32>>} =
               hd(FakeUART.writes(device.uart))
    end

    test "fails when the stub does not start" do
      handler = fn
        {0x06, _} -> [response(:mem_end, <<0, 0, 0, 0>>), "NOPE"]
        req -> stub_handler().(req)
      end

      device = device(handler, chip: :esp32c3, stub?: false)
      assert {:error, {:stub_start_failed, "NOPE"}} = Bootloader.load_stub(device)
    end

    test "fails for chips without a shipped stub" do
      device = device(fn _ -> [] end, chip: :esp32h4, stub?: false)
      assert {:error, {:no_stub, :esp32h4}} = Bootloader.load_stub(device)
    end
  end

  describe "change_baud/2" do
    test "stub: sends new and current baud, waits for the reply, then switches the host" do
      device = device(fn {0x0F, _} -> [response(:change_baudrate, <<0, 0>>)] end, stub?: true)
      assert {:ok, %Device{baud: 921_600}} = Bootloader.change_baud(device, 921_600)
      assert [{0x0F, <<921_600::little-32, 115_200::little-32>>}] = FakeUART.writes(device.uart)
      assert [{:configure, [speed: 921_600]}, :flush] = FakeUART.calls(device.uart)
    end

    test "ROM: sends 0 as the current baud" do
      device =
        device(fn {0x0F, _} -> [response(:change_baudrate, <<0, 0, 0, 0>>)] end, stub?: false)

      assert {:ok, _} = Bootloader.change_baud(device, 460_800)
      assert [{0x0F, <<460_800::little-32, 0::little-32>>}] = FakeUART.writes(device.uart)
    end

    test "ESP32 ROM: scales the baud by the ROM's crystal estimate" do
      # cali 8320, 8M clock 9 -> ROM estimate 29.25 MHz -> nominal 26 MHz -> baud * 29.25 / 26
      device =
        device(
          fn
            {0x0A, <<0x3FF5F06C::little-32>>} -> [response(:read_reg, <<0, 0, 0, 0>>, 8320 <<< 7)]
            {0x0A, <<0x3FF5A010::little-32>>} -> [response(:read_reg, <<0, 0, 0, 0>>, 9)]
            {0x0F, _} -> [response(:change_baudrate, <<0, 0, 0, 0>>)]
          end,
          chip: :esp32,
          stub?: false
        )

      assert {:ok, _} = Bootloader.change_baud(device, 115_200)

      assert {0x0F, <<129_600::little-32, 0::little-32>>} =
               List.last(FakeUART.writes(device.uart))
    end

    test "does not switch the host when the device rejects the change" do
      device = device(fn {0x0F, _} -> [response(:change_baudrate, <<1, 5>>)] end, stub?: true)
      assert {:error, {:change_baudrate, 5}} = Bootloader.change_baud(device, 921_600)
      assert FakeUART.calls(device.uart) == []
    end

    test "is unsupported on the ESP8266 ROM" do
      device = device(fn _ -> [] end, chip: :esp8266, stub?: false)
      assert {:error, :stub_required} = Bootloader.change_baud(device, 921_600)
    end
  end

  test "flash_block_size/1" do
    assert Bootloader.flash_block_size(%Device{stub?: true}) == 0x4000
    assert Bootloader.flash_block_size(%Device{stub?: false}) == 0x400
    assert Bootloader.flash_block_size(%Device{stub?: true, usb_otg?: true}) == 0x800
  end

  test "spi_attach/1 sends the ROM's 8-byte argument" do
    device = device(fn {0x0D, _} -> [response(:spi_attach, <<0, 0, 0, 0>>)] end, stub?: false)
    assert :ok = Bootloader.spi_attach(device)
    assert [{0x0D, <<0::little-32, 0::little-32>>}] = FakeUART.writes(device.uart)
  end

  describe "flash_begin/3" do
    test "stub: four words plus the encrypted word" do
      device = device(fn {0x02, _} -> [response(:flash_begin, <<0, 0>>)] end, stub?: true)
      assert {:ok, 0x4000} = Bootloader.flash_begin(device, 0x5000, 0x10000)

      assert [
               {0x02,
                <<0x5000::little-32, 2::little-32, 0x4000::little-32, 0x10000::little-32,
                  0::little-32>>}
             ] =
               FakeUART.writes(device.uart)
    end

    test "ESP32 ROM: four words only" do
      device =
        device(fn {0x02, _} -> [response(:flash_begin, <<0, 0, 0, 0>>)] end,
          chip: :esp32,
          stub?: false
        )

      assert {:ok, 0x400} = Bootloader.flash_begin(device, 0x401, 0x1000)

      assert [{0x02, <<0x401::little-32, 2::little-32, 0x400::little-32, 0x1000::little-32>>}] =
               FakeUART.writes(device.uart)
    end

    test "ESP32-C3 ROM: four words plus the encrypted word" do
      device =
        device(fn {0x02, _} -> [response(:flash_begin, <<0, 0, 0, 0>>)] end,
          chip: :esp32c3,
          stub?: false
        )

      assert {:ok, 0x400} = Bootloader.flash_begin(device, 0x400, 0x0)

      assert [
               {0x02,
                <<0x400::little-32, 1::little-32, 0x400::little-32, 0::little-32, 0::little-32>>}
             ] = FakeUART.writes(device.uart)
    end
  end

  describe "flash_block/3" do
    test "retries a failed block up to three times" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      device =
        device(fn {0x03, _} ->
          if Agent.get_and_update(counter, &{&1, &1 + 1}) < 2,
            do: [response(:flash_data, <<1, 6>>)],
            else: [response(:flash_data, <<0, 0>>)]
        end)

      assert :ok = Bootloader.flash_block(device, <<1, 2, 3>>, 4)
      assert length(FakeUART.writes(device.uart)) == 3
    end

    test "gives up after three attempts" do
      device = device(fn {0x03, _} -> [response(:flash_data, <<1, 6>>)] end)
      assert {:error, {:flash_data, 6}} = Bootloader.flash_block(device, <<1>>, 0)
      assert length(FakeUART.writes(device.uart)) == 3
    end

    test "sends the block header, data and checksum" do
      device = device(fn {0x03, _} -> [response(:flash_data, <<0, 0>>)] end)
      assert :ok = Bootloader.flash_block(device, <<0xAA, 0xBB>>, 7)

      assert [{0x03, <<2::little-32, 7::little-32, 0::little-32, 0::little-32, 0xAA, 0xBB>>}] =
               FakeUART.writes(device.uart)
    end
  end

  test "flash_end/2 encodes reboot as 0 and run-user-code as 1" do
    device = device(fn {0x04, _} -> [response(:flash_end, <<0, 0>>)] end)
    assert :ok = Bootloader.flash_end(device, true)
    assert :ok = Bootloader.flash_end(device, false)
    assert [{0x04, <<0::little-32>>}, {0x04, <<1::little-32>>}] = FakeUART.writes(device.uart)
  end

  describe "flash_md5/3" do
    test "stub returns 16 raw bytes" do
      digest = :crypto.hash(:md5, "abc")

      device =
        device(fn {0x13, _} -> [response(:spi_flash_md5, digest <> <<0, 0>>)] end, stub?: true)

      assert {:ok, ^digest} = Bootloader.flash_md5(device, 0x10000, 3)

      assert [{0x13, <<0x10000::little-32, 3::little-32, 0::little-32, 0::little-32>>}] =
               FakeUART.writes(device.uart)
    end

    test "ROM returns 32 hex characters" do
      digest = :crypto.hash(:md5, "abc")
      hex = Base.encode16(digest, case: :lower)

      device =
        device(fn {0x13, _} -> [response(:spi_flash_md5, hex <> <<0, 0, 0, 0>>)] end,
          stub?: false
        )

      assert {:ok, ^digest} = Bootloader.flash_md5(device, 0, 3)
    end
  end

  test "erase_flash/1 requires the stub" do
    device = device(fn {0xD0, <<>>} -> [response(:erase_flash, <<0, 0>>)] end, stub?: true)
    assert :ok = Bootloader.erase_flash(device)
    assert {:error, :stub_required} = Bootloader.erase_flash(%{device | stub?: false})
  end
end
