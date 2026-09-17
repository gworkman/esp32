defmodule Esp32Test do
  use ExUnit.Case, async: true
  alias Esp32.{Device, FakeUART, Image}
  import Esp32.FakeUART, only: [response: 2, response: 3]

  @sync_rom List.duplicate(response(:sync, <<0, 0, 0, 0>>, 0x80), 8)
  @sync_stub List.duplicate(response(:sync, <<0, 0>>, 0), 8)
  @ok_rom <<0, 0, 0, 0>>
  @ok_stub <<0, 0>>

  defp security_info(chip_id), do: <<0::little-32, 0, 0::56, chip_id::little-32, 1::little-32>>

  defp rom_c3_handler do
    fn
      {0x08, _} -> @sync_rom
      {0x14, _} -> [response(:get_security_info, security_info(5) <> @ok_rom)]
      {0x05, _} -> [response(:mem_begin, @ok_rom)]
      {0x07, _} -> [response(:mem_data, @ok_rom)]
      {0x06, _} -> [response(:mem_end, @ok_rom), "OHAI"]
      {0x0F, _} -> [response(:change_baudrate, @ok_stub)]
    end
  end

  defp device(handler, attrs \\ []) do
    {:ok, uart} = FakeUART.start_link(handler)
    struct!(%Device{uart: uart, port: "ttyUSB0", baud: 115_200}, attrs)
  end

  defp ops(device), do: device.uart |> FakeUART.writes() |> Enum.map(&elem(&1, 0))

  describe "establish/2" do
    test "syncs, detects the chip, loads the stub and changes baud" do
      device = device(rom_c3_handler())
      assert {:ok, esp} = Esp32.establish(device, baud_rate: 921_600)
      assert %Device{chip: :esp32c3, stub?: true, baud: 921_600} = esp
      assert {:configure, [speed: 921_600]} in FakeUART.calls(device.uart)
      assert [0x08, 0x14, 0x05 | _] = ops(device)
      assert List.last(ops(device)) == 0x0F
    end

    test "skips the stub upload when it is already running" do
      handler = fn
        {0x08, _} -> @sync_stub
        {0x14, _} -> [response(:get_security_info, security_info(13) <> @ok_stub)]
      end

      assert {:ok, %Device{chip: :esp32c6, stub?: true, baud: 115_200}} =
               Esp32.establish(device(handler), [])
    end

    test "use_stub: false stays on the ROM loader" do
      device = device(rom_c3_handler())
      assert {:ok, %Device{stub?: false}} = Esp32.establish(device, use_stub: false)
      refute 0x05 in ops(device)
    end

    test "detects USB-OTG on the ESP32-S3" do
      handler = fn
        {0x08, _} -> @sync_rom
        {0x14, _} -> [response(:get_security_info, security_info(9) <> @ok_rom)]
        {0x0A, <<0x3FCEF14C::little-32>>} -> [response(:read_reg, @ok_rom, 3)]
      end

      assert {:ok, %Device{chip: :esp32s3, usb_otg?: true}} =
               Esp32.establish(device(handler), use_stub: false)
    end

    test "retries sync across connect attempts and reports failure" do
      device = device(fn _ -> [] end, reset: :classic)
      assert {:error, :sync_failed} = Esp32.establish(device, connect_attempts: 2)
      assert Enum.count(ops(device), &(&1 == 0x08)) == 10
      assert Enum.count(FakeUART.calls(device.uart), &(&1 == {:set_rts, true})) == 2
    end

    test "the ESP8266 needs the stub" do
      handler = fn
        {0x08, _} -> @sync_rom
        {0x14, _} -> List.duplicate(response(:sync, <<1, 5, 0, 0>>), 8)
        {0x0A, _} -> [response(:read_reg, @ok_rom, 0xFFF0C101)]
      end

      assert {:error, {:stub_required, :esp8266}} =
               Esp32.establish(device(handler), use_stub: false)
    end

    test "returns detection errors" do
      handler = fn
        {0x08, _} -> @sync_rom
        {0x14, _} -> [response(:get_security_info, security_info(99) <> @ok_rom)]
      end

      assert {:error, {:unknown_chip_id, 99}} = Esp32.establish(device(handler), [])
    end
  end

  # A minimal ESP32-C3 image with a SHA256 digest, as produced by Esp32.ImageTest.build/1
  defp image(chip_id \\ 5) do
    header = <<0xE9, 1, 2, 0x20, 0x40080000::little-32>>
    ext = <<0xEE, 0, 0, 0, chip_id::little-16, 0::72, 1>>
    segment = <<0x1000::little-32, 4::little-32, 1, 2, 3, 4>>
    body = header <> ext <> segment

    image =
      body <>
        :binary.copy(<<0>>, 47 - byte_size(body)) <> <<Esp32.Protocol.checksum(<<1, 2, 3, 4>>)>>

    image <> :crypto.hash(:sha256, image)
  end

  defp flash_handler(written) do
    fn
      {0x0D, _} ->
        [response(:spi_attach, @ok_rom)]

      {0x02, _} ->
        [response(:flash_begin, @ok_stub)]

      {0x03, <<_::little-32, _::little-32, _::64, data::binary>>} ->
        Agent.update(written, &(&1 <> data))
        [response(:flash_data, @ok_stub)]

      {0x04, _} ->
        [response(:flash_end, @ok_stub)]

      {0x13, <<_offset::little-32, size::little-32, _::64>>} ->
        digest = :crypto.hash(:md5, binary_part(Agent.get(written, & &1), 0, size))
        [response(:spi_flash_md5, digest <> @ok_stub)]
    end
  end

  describe "flash/4" do
    setup do
      {:ok, written} = Agent.start_link(fn -> <<>> end)
      %{written: written}
    end

    test "writes padded blocks, verifies, and leaves the stub running", %{written: written} do
      device = device(flash_handler(written), chip: :esp32c3, stub?: true)
      assert :ok = Esp32.flash(device, image(), 0x10000)
      assert ops(device) == [0x02, 0x03, 0x13, 0x04]
      assert byte_size(Agent.get(written, & &1)) == 0x4000
      assert binary_part(Agent.get(written, & &1), 0, 80) == image()
      assert {0x04, <<1::little-32>>} = List.last(FakeUART.writes(device.uart))
    end

    test "reboot: true", %{written: written} do
      device = device(flash_handler(written), chip: :esp32c3, stub?: true, reset: :classic)
      assert :ok = Esp32.flash(device, image(), 0x10000, reboot: true)
      assert {0x04, <<1::little-32>>} = List.last(FakeUART.writes(device.uart))
      assert {:set_rts, true} in FakeUART.calls(device.uart)
    end

    test "reboot: true without a reset strategy", %{written: written} do
      device = device(flash_handler(written), chip: :esp32c3, stub?: true)

      assert {:error, :no_reset_strategy} =
               Esp32.flash(device, image(), 0x10000, reboot: true, verify: false)
    end

    test "verify: false skips the MD5 check", %{written: written} do
      device = device(flash_handler(written), chip: :esp32c3, stub?: true)
      assert :ok = Esp32.flash(device, image(), 0x10000, verify: false)
      refute 0x13 in ops(device)
    end

    test "reports an MD5 mismatch", %{written: written} do
      handler = fn
        {0x13, _} -> [response(:spi_flash_md5, :binary.copy(<<0>>, 16) <> @ok_stub)]
        req -> flash_handler(written).(req)
      end

      assert {:error, :verify_failed} =
               Esp32.flash(device(handler, chip: :esp32c3, stub?: true), image(), 0x10000)
    end

    test "ROM loader: attaches SPI first and never sends FLASH_END", %{written: written} do
      device = device(flash_handler(written), chip: :esp32c3, stub?: false)
      assert :ok = Esp32.flash(device, image(), 0x10000, verify: false)
      assert ops(device) == [0x0D, 0x02, 0x03]

      device = device(flash_handler(written), chip: :esp32c3, stub?: false, reset: :classic)
      assert :ok = Esp32.flash(device, image(), 0x10000, verify: false, reboot: true)
      assert ops(device) == [0x0D, 0x02, 0x03]
      assert {:set_rts, true} in FakeUART.calls(device.uart)
    end

    test "refuses an image built for another chip", %{written: written} do
      device = device(flash_handler(written), chip: :esp32c3, stub?: true)
      assert {:error, {:wrong_chip, :esp32s3}} = Esp32.flash(device, image(9), 0x10000)
      assert ops(device) == []
    end

    test "flashes non-image data such as a partition table", %{written: written} do
      device = device(flash_handler(written), chip: :esp32c3, stub?: true)
      assert :ok = Esp32.flash(device, <<0xAA, 0x50, 1, 2, 3>>, 0x8000, flash_mode: :dio)
      assert binary_part(Agent.get(written, & &1), 0, 5) == <<0xAA, 0x50, 1, 2, 3>>

      assert {0x02, <<8::little-32, _::binary>>} = hd(FakeUART.writes(device.uart))

      assert binary_part(Agent.get(written, & &1), 0, 8) ==
               <<0xAA, 0x50, 1, 2, 3, 0xFF, 0xFF, 0xFF>>
    end

    test "patches the header only at the bootloader offset", %{written: written} do
      device = device(flash_handler(written), chip: :esp32c3, stub?: true)
      assert :ok = Esp32.flash(device, image(), 0x0, flash_mode: :qio, flash_size: "16MB")

      assert {:ok, %Image{flash_mode: 0, flash_size: 4}} =
               Image.parse(binary_part(Agent.get(written, & &1), 0, 80))

      device = device(flash_handler(written), chip: :esp32c3, stub?: true)

      assert {:error, {:invalid_flash_freq, "60m"}} =
               Esp32.flash(device, image(), 0x0, flash_freq: "60m")

      assert :ok = Esp32.flash(device, image(), 0x10000, flash_freq: "60m", verify: false)
    end
  end

  test "flash_file/4 reads the file" do
    {:ok, written} = Agent.start_link(fn -> <<>> end)
    path = Path.join(System.tmp_dir!(), "esp32_test_#{System.unique_integer([:positive])}.bin")
    File.write!(path, image())
    on_exit(fn -> File.rm(path) end)

    device = device(flash_handler(written), chip: :esp32c3, stub?: true)
    assert :ok = Esp32.flash_file(device, path, 0x10000)
    assert {:error, :enoent} = Esp32.flash_file(device, path <> ".missing", 0x10000)
  end

  test "erase/1, read_reg/2, write_reg/3 and close/1" do
    device =
      device(
        fn
          {0xD0, _} -> [response(:erase_flash, @ok_stub)]
          {0x0A, _} -> [response(:read_reg, @ok_stub, 5)]
          {0x09, _} -> [response(:write_reg, @ok_stub)]
        end,
        chip: :esp32c3,
        stub?: true
      )

    assert :ok = Esp32.erase(device)
    assert {:ok, 5} = Esp32.read_reg(device, 0x10)
    assert :ok = Esp32.write_reg(device, 0x10, 5)
    assert :ok = Esp32.reset(%{device | reset: :usb_jtag_serial})
    assert :ok = Esp32.close(device)
    refute Process.alive?(device.uart)
  end
end
