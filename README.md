# Esp32

A library for managing ESP32 firmware on Nerves and other Elixir systems. This
package implements the ESP32 serial bootloader protocol and handles hardware
reset and strapping pins to automate entry into bootloader mode.

## Features

- Supports all families of ESP32 chips
- Two stage bootloader, including stub loading for flash programming
- Automatic discovery and reset of USB-connected ESP32 devices

## Usage

To use `Esp32`, you need to provide the UART port and reset/boot options. For
many development boards, you can use the automatic reset feature via DTR/RTS.

```elixir
# Automatic discovery and reset (common for devboards via DTR/RTS)
{:ok, uart} = Esp32.connect("auto", auto_reset: true, baud_rate: 921600)

# Detect the chip family
{:ok, chip} = Esp32.detect_chip(uart)
IO.puts("Connected to: #{chip}")

# Flash a firmware file (patches header metadata if written to bootloader offset)
:ok = Esp32.flash_file(uart, "firmware.bin", 0x10000, reboot: true)

# Flash a raw binary blob
binary_data = <<...>>
:ok = Esp32.flash(uart, binary_data, 0x8000)

# Erase the entire flash chip
:ok = Esp32.erase(uart)

# Close the connection when done
Esp32.UART.close(uart)
```

### Connection Options

When calling `Esp32.connect/2`, you can specify several options:

- `:initial_baud_rate` - The baud rate used for the initial synchronization and
  loading the flasher stub (default: 115200).
- `:baud_rate` - The target baud rate to use after the flasher stub is loaded.
  This is typically much higher (e.g., 921600) to speed up flashing.
- `:auto_reset` - When set to `true`, the library will use the DTR and RTS lines
  to automatically put the ESP32 into bootloader mode. This is common for most
  USB-based development boards.
- `:reset` - When set to `false`, the library will skip the hardware reset
  sequence and attempt to synchronize with an already running bootloader.
  (default: `true`).
- `:reset_pin` and `:boot_pin` - GPIO pin names to use for manual reset and
  strapping pin control (e.g., for custom Nerves hardware).

### Common Firmware Offsets

When flashing your device, ensure you use the correct memory offsets. These
offsets vary depending on the chip family:

| Chip Family  | Bootloader | Partition Table | Application |
| ------------ | ---------- | --------------- | ----------- |
| **ESP32**    | `0x1000`   | `0x8000`        | `0x10000`   |
| **ESP32-S2** | `0x1000`   | `0x8000`        | `0x10000`   |
| **ESP32-S3** | `0x0`      | `0x8000`        | `0x10000`   |
| **ESP32-C2** | `0x0`      | `0x8000`        | `0x10000`   |
| **ESP32-C3** | `0x0`      | `0x8000`        | `0x10000`   |
| **ESP32-C6** | `0x0`      | `0x8000`        | `0x10000`   |

_Note: For chips with a `0x0` bootloader offset, the library automatically
handles header patching if you use `flash_file/4` at that address._

## Installation

Add `esp32` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:esp32, "~> 0.1.0"},
  ]
end
```

Documentation can be generated with
[ExDoc](https://github.com/elixir-lang/ex_doc) and published on
[HexDocs](https://hexdocs.pm). Once published, the docs can be found at
<https://hexdocs.pm/esp32>.

## License

MIT License. The ESP32 stub firmware binaries found in `priv/stubs` are from the
[`esptool`](https://github.com/espressif/esptool) project and are licensed
separately (GPL-2.0). Please see the source repository for more details
