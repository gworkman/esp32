# ESP32

The goal of this project is to develop a library for Elixir and Nerves which can
help manage the firmware on an attached ESP32 device. Specifically, this package
will implement the ESP32 serial bootloader protocol and manage the reset and
strapping pins of the device to force entry into bootloader mode

## Design principles

- Use the Circuits.UART library for communicating with ESP32 via serial
- Use the Circuits.GPIO library for controlling the reset and strapping pins of
  the ESP32
- All pins and ports should be configurable via application config (but since
  this is targetting Nerves devices, we can assume the UART port is always the
  same)
- Document all public functions with `@spec` and `@doc` (describe keyword
  options if necessary)

## Tools

- Use the Tidewave `get_docs` tool to read the documentation for Elixir
  packages. Do this every time before using a new function or module
