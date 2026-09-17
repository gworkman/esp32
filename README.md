# Esp32

A library for managing ESP32 firmware on Nerves and other Elixir systems. This
package implements the ESP32 serial bootloader protocol and handles hardware
reset and strapping pins to automate entry into bootloader mode.

## Features

- Flasher-stub support for ESP32, S2, S3, C2, C3, C5, C6, C61, H2, P4 and
  ESP8266; other families (H21, H4, E22, S31) can be flashed through the ROM
  loader with `use_stub: false`
- Two stage bootloader, including stub loading for flash programming
- Automatic discovery and reset of USB-connected ESP32 devices

## Usage

```elixir
# Find a USB-connected board, reset it via DTR/RTS, and load the flasher stub
{:ok, esp} = Esp32.connect(:auto, baud_rate: 921_600)
esp.chip #=> :esp32c3

# Flash files; bootloader headers get their flash parameters patched
:ok = Esp32.flash_file(esp, "bootloader.bin", 0x0, flash_mode: :dio, flash_size: "4MB")
:ok = Esp32.flash_file(esp, "partition-table.bin", 0x8000)
:ok = Esp32.flash_file(esp, "firmware.bin", 0x10000, reboot: true)

# Or flash a binary you already have in memory
binary = File.read!("firmware.bin")
:ok = Esp32.flash(esp, binary, 0x10000)

# Erase the entire flash chip
:ok = Esp32.erase(esp)

# Hard-reset into the application without flashing
:ok = Esp32.reset(esp)

Esp32.close(esp)
```

On Nerves hardware where EN and IO0 are wired to GPIOs, pass the pin names:

```elixir
{:ok, esp} = Esp32.connect("ttyS1", reset_pin: "GPIO17", boot_pin: "GPIO27")
```

### Connection Options

- `:baud_rate` - speed used after connecting; higher rates such as 921600 speed up
  flashing (default 115200).
- `:initial_baud_rate` - speed used to connect and load the flasher stub (default
  115200).
- `:use_stub` - load the flasher stub. Without it flashing uses the slower ROM
  loader and `erase/1` is unavailable (default `true`). The ESP8266 is only
  supported with the stub.
- `:reset` - reset the chip into the bootloader. Set to `false` when it is already
  there (default `true`).
- `:reset_pin` and `:boot_pin` - `Circuits.GPIO` pin names wired to EN and IO0. When
  absent, the DTR/RTS lines are used, with the sequence chosen by the port's USB ids.
- `:connect_attempts` - how many reset/sync rounds to try (default 7).

### Flash Options

`flash/4` and `flash_file/4` accept `:flash_mode` (`:qio`, `:qout`, `:dio`, `:dout`),
`:flash_freq` (e.g. `"40m"`) and `:flash_size` (e.g. `"4MB"`), which rewrite the
header of an image written at the chip's bootloader offset; `:verify` (default
`true`) compares the flash MD5 afterwards; `:reboot` (default `false`) hard-resets
the chip into the application when done (see `Esp32.reset/1`); it needs a reset
strategy, so it fails with `{:error, :no_reset_strategy}` after `connect(port,
reset: false)`. Images built for a different chip are refused.

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

_Note: `flash_file/4` patches the header when the offset matches the chip's bootloader offset (`0x1000` on ESP32/S2, `0x2000` on C5/P4/H4/S31, `0x0` elsewhere)._

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
