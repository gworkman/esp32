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

To use `Esp32`, you need to know the UART port and the GPIO pins used for
reset and bootloader entry. For many development boards, you can use the
automatic reset feature. By default, it will attempt to load a flasher stub
for better performance.

```elixir
# Option 1: Automatic reset (common for devboards via DTR/RTS)
{:ok, uart} = Esp32.connect("/dev/ttyUSB0", :auto_reset, nil, use_stub: true)

# Option 2: Direct GPIO control (common for custom Nerves hardware)
{:ok, uart} = Esp32.connect("/dev/ttyS0", "en_pin_name", "io0_pin_name", baud_rate: 921600)
```
# Detect the chip family
{:ok, chip} = Esp32.detect_chip(uart)
IO.puts("Connected to: #{chip}")

# Flash a firmware image to offset 0x10000
:ok = Esp32.flash_file(uart, "path/to/firmware.bin", 0x10000, reboot: true)
```

# Read a 32-bit register (e.g., chip identification register)
{:ok, val} = Esp32.read_reg(uart, 0x3FF44000)
IO.inspect(val, label: "Register Value")
```
# Close the connection when done
Circuits.UART.close(uart)
```

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
