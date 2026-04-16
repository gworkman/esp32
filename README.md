# Esp32

A library for managing ESP32 firmware on Nerves and other Elixir systems. This
package implements the ESP32 serial bootloader protocol and handles hardware
reset and strapping pins to automate entry into bootloader mode.

## Features

- **SLIP Encoding/Decoding**: Full support for Serial Line IP framing.
- **Bootloader Protocol**: Implementation of the Espressif UART bootloader
  protocol.
- **Hardware Control**: Integrated management of EN (reset) and IO0 (strapping)
  pins via `Circuits.GPIO`.
- **Serial Communication**: Robust communication via `Circuits.UART`.

## Usage

To use `Esp32`, you need to provide the UART port and reset/boot options. For
many development boards, you can use the automatic reset feature via DTR/RTS.

```elixir
# Option 1: Automatic discovery and reset (common for devboards via DTR/RTS)
{:ok, uart} = Esp32.connect("auto", auto_reset: true)

# Option 2: Direct GPIO control (common for custom Nerves hardware)
{:ok, uart} = Esp32.connect("/dev/ttyS0", reset_pin: "en", boot_pin: "io0", baud_rate: 921600)

# Detect the chip family
{:ok, chip} = Esp32.detect_chip(uart)
IO.puts("Connected to: \#{chip}")
```

### Connection Options

When calling `Esp32.connect/2`, you can specify several options:

* `:initial_baud_rate` - The baud rate used for the initial synchronization and
  loading the flasher stub (default: 115200).
* `:baud_rate` - The target baud rate to use after the flasher stub is loaded.
  This is typically much higher (e.g., 921600) to speed up flashing.
* `:auto_reset` - When set to `true`, the library will use the DTR and RTS lines
  to automatically put the ESP32 into bootloader mode. This is common for most
  USB-based development boards.
* `:reset` - When set to `false`, the library will skip the hardware reset
  sequence and attempt to synchronize with an already running bootloader. (default: `true`).
* `:reset_pin` and `:boot_pin` - GPIO pin names to use for manual reset and strapping
  pin control (e.g., for custom Nerves hardware).

## Installation

Add `esp32` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:esp32, "~> 0.1.0"},
    {:circuits_gpio, "~> 2.0"},
    {:circuits_uart, "~> 1.0"}
  ]
end
```

Documentation can be generated with
[ExDoc](https://github.com/elixir-lang/ex_doc) and published on
[HexDocs](https://hexdocs.pm). Once published, the docs can be found at
<https://hexdocs.pm/esp32>.
