defmodule Esp32.ChipTest do
  use ExUnit.Case, async: true
  alias Esp32.Chip

  test "from_id/1 maps security-info chip ids" do
    assert Chip.from_id(0) == :esp32
    assert Chip.from_id(5) == :esp32c3
    assert Chip.from_id(23) == :esp32c5
    assert Chip.from_id(18) == :esp32p4
    assert Chip.from_id(20) == :esp32c61
    assert Chip.from_id(99) == nil
    assert Chip.from_id(nil) == nil
  end

  test "from_magic/1 only knows the chips that report a magic value" do
    assert Chip.from_magic(0xFFF0C101) == :esp8266
    assert Chip.from_magic(0x00F01D83) == :esp32
    assert Chip.from_magic(0x000007C6) == :esp32s2
    assert Chip.from_magic(0x20120707) == nil
  end

  test "bootloader_offset/1" do
    assert Chip.bootloader_offset(:esp32) == 0x1000
    assert Chip.bootloader_offset(:esp32s2) == 0x1000
    assert Chip.bootloader_offset(:esp32c3) == 0x0
    assert Chip.bootloader_offset(:esp32c5) == 0x2000
    assert Chip.bootloader_offset(:esp32p4) == 0x2000
    assert Chip.bootloader_offset(:esp32h4) == 0x2000
  end

  test "stub/1 names the shipped stub or nil" do
    assert Chip.stub(:esp32c6) == "esp32c6"
    assert Chip.stub(:esp32h4) == nil

    for name <- Chip.names(), stub = Chip.stub(name), stub != nil do
      assert File.exists?(Application.app_dir(:esp32, "priv/stubs/#{stub}.json")), stub
    end
  end

  test "ROM FLASH_BEGIN takes an extended parameter block except on ESP32 and ESP8266" do
    refute Chip.rom_extended_flash_begin?(:esp32)
    refute Chip.rom_extended_flash_begin?(:esp8266)
    assert Chip.rom_extended_flash_begin?(:esp32s2)
    assert Chip.rom_extended_flash_begin?(:esp32c3)
  end

  test "usb_otg_check/1" do
    assert Chip.usb_otg_check(:esp32s2) == {0x3FFFFD14, 2}
    assert Chip.usb_otg_check(:esp32s3) == {0x3FCEF14C, 3}
    assert Chip.usb_otg_check(:esp32e22) == {0x3111B700, 3}
    assert Chip.usb_otg_check(:esp32c3) == nil
  end

  test "flash_freq/2 is chip specific" do
    assert Chip.flash_freq(:esp32, "80m") == {:ok, 0xF}
    assert Chip.flash_freq(:esp32, "26m") == {:ok, 0x1}
    assert Chip.flash_freq(:esp32c6, "80m") == {:ok, 0x0}
    assert Chip.flash_freq(:esp32c2, "60m") == {:ok, 0xF}
    assert Chip.flash_freq(:esp32h2, "48m") == {:ok, 0xF}
    assert Chip.flash_freq(:esp32h4, "48m") == {:ok, 0x0}
    assert Chip.flash_freq(:esp32c3, "60m") == :error
    assert Chip.flash_freq(:esp32c3, "keep") == :error
  end

  test "flash_size/2" do
    assert Chip.flash_size(:esp32c3, "4MB") == {:ok, 0x20}
    assert Chip.flash_size(:esp32s3, "32MB") == {:ok, 0x50}
    assert Chip.flash_size(:esp8266, "1MB") == {:ok, 0x20}
    assert Chip.flash_size(:esp8266, "512KB") == {:ok, 0x00}
    assert Chip.flash_size(:esp32, "3MB") == :error
  end
end
