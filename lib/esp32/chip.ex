defmodule Esp32.Chip do
  @moduledoc """
  Per-family constants, copied from esptool's target definitions.
  """

  @type name ::
          :esp8266
          | :esp32
          | :esp32s2
          | :esp32s3
          | :esp32c3
          | :esp32c2
          | :esp32c6
          | :esp32c61
          | :esp32c5
          | :esp32h2
          | :esp32h21
          | :esp32h4
          | :esp32p4
          | :esp32e22
          | :esp32s31

  @esp32_freq %{"80m" => 0xF, "40m" => 0x0, "26m" => 0x1, "20m" => 0x2}
  @c5_freq %{"80m" => 0xF, "40m" => 0x0, "20m" => 0x2}
  @h2_freq %{"48m" => 0xF, "24m" => 0x0, "16m" => 0x1, "12m" => 0x2}

  @esp32_sizes %{
    "1MB" => 0x00,
    "2MB" => 0x10,
    "4MB" => 0x20,
    "8MB" => 0x30,
    "16MB" => 0x40,
    "32MB" => 0x50,
    "64MB" => 0x60,
    "128MB" => 0x70
  }

  @esp8266_sizes %{
    "512KB" => 0x00,
    "256KB" => 0x10,
    "1MB" => 0x20,
    "2MB" => 0x30,
    "4MB" => 0x40,
    "2MB-c1" => 0x50,
    "4MB-c1" => 0x60,
    "8MB" => 0x80,
    "16MB" => 0x90
  }

  @defaults %{
    id: nil,
    magic: nil,
    bootloader_offset: 0x0,
    stub: nil,
    extended_flash_begin?: true,
    usb_otg: nil,
    freq: @esp32_freq,
    sizes: @esp32_sizes
  }

  @chips Map.new(
           [
             esp8266: %{
               magic: 0xFFF0C101,
               stub: "esp8266",
               extended_flash_begin?: false,
               sizes: @esp8266_sizes
             },
             esp32: %{
               id: 0,
               magic: 0x00F01D83,
               bootloader_offset: 0x1000,
               stub: "esp32",
               extended_flash_begin?: false
             },
             esp32s2: %{
               id: 2,
               magic: 0x000007C6,
               bootloader_offset: 0x1000,
               stub: "esp32s2",
               usb_otg: {0x3FFFFD14, 2}
             },
             esp32s3: %{id: 9, stub: "esp32s3", usb_otg: {0x3FCEF14C, 3}},
             esp32c3: %{id: 5, stub: "esp32c3"},
             esp32c2: %{
               id: 12,
               stub: "esp32c2",
               freq: %{"60m" => 0xF, "30m" => 0x0, "20m" => 0x1, "15m" => 0x2}
             },
             # 80m is encoded as 0x0 to work around a ROM clock divider bug
             esp32c6: %{
               id: 13,
               stub: "esp32c6",
               freq: %{"80m" => 0x0, "40m" => 0x0, "20m" => 0x2}
             },
             esp32c61: %{id: 20, stub: "esp32c61", freq: @c5_freq},
             esp32c5: %{id: 23, bootloader_offset: 0x2000, stub: "esp32c5", freq: @c5_freq},
             esp32h2: %{id: 16, stub: "esp32h2", freq: @h2_freq},
             esp32h21: %{id: 25, freq: @h2_freq},
             esp32h4: %{
               id: 28,
               bootloader_offset: 0x2000,
               freq: %{"48m" => 0x0, "24m" => 0x0, "16m" => 0x1, "12m" => 0x2}
             },
             esp32p4: %{id: 18, bootloader_offset: 0x2000, stub: "esp32p4"},
             esp32e22: %{id: 31, usb_otg: {0x3111B700, 3}},
             esp32s31: %{id: 32, bootloader_offset: 0x2000, freq: @c5_freq}
           ],
           fn {name, overrides} -> {name, Map.merge(@defaults, overrides)} end
         )

  @spec names() :: [name()]
  def names, do: Map.keys(@chips)

  @doc "Chip family for a security-info chip id."
  @spec from_id(integer() | nil) :: name() | nil
  def from_id(id), do: find(:id, id)

  @doc "Chip family for the value of the ROM magic register 0x40001000."
  @spec from_magic(integer() | nil) :: name() | nil
  def from_magic(magic), do: find(:magic, magic)

  defp find(_key, nil), do: nil

  defp find(key, value) do
    Enum.find_value(@chips, fn {name, info} -> if info[key] == value, do: name end)
  end

  @spec bootloader_offset(name()) :: non_neg_integer()
  def bootloader_offset(name), do: fetch(name).bootloader_offset

  @doc "Base name of the flasher stub in `priv/stubs`, or nil when none is shipped."
  @spec stub(name()) :: String.t() | nil
  def stub(name), do: fetch(name).stub

  @doc "Whether the ROM loader's FLASH_BEGIN takes the fifth (encrypted) word."
  @spec rom_extended_flash_begin?(name()) :: boolean()
  def rom_extended_flash_begin?(name), do: fetch(name).extended_flash_begin?

  @doc "Register and value that indicate the ROM console is on USB-OTG, if detectable."
  @spec usb_otg_check(name()) :: {non_neg_integer(), non_neg_integer()} | nil
  def usb_otg_check(name), do: fetch(name).usb_otg

  @doc "Image header nibble for a flash frequency such as `\"40m\"`."
  @spec flash_freq(name(), String.t()) :: {:ok, non_neg_integer()} | :error
  def flash_freq(name, freq), do: Map.fetch(fetch(name).freq, freq)

  @doc "Image header byte for a flash size such as `\"4MB\"`."
  @spec flash_size(name(), String.t()) :: {:ok, non_neg_integer()} | :error
  def flash_size(name, size), do: Map.fetch(fetch(name).sizes, size)

  defp fetch(name), do: Map.fetch!(@chips, name)
end
