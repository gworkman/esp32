# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

The bootloader protocol was reworked to follow esptool closely and the public
API was rebuilt around an `%Esp32.Device{}`. Verified on an ESP32-C3 and an
ESP32-S3 with both the flasher stub and the ROM loader.

### Added

- `Esp32.reset/1` hard-resets the chip into its application. `reboot: true` on
  `flash/4` does the same.
- `Esp32.close/1` and `Esp32.write_reg/3`.
- Flash writes are verified by MD5 and failed blocks are retried.
- Images built for a different chip are refused. Non-image data such as
  partition tables can be flashed.
- Chip table copied from esptool, adding the ESP32-C5, C61, P4, H21, H4, E22 and
  S31.
- Unit tests run against a fake UART, so `mix test` needs no hardware.

### Changed

- `Esp32.connect/2` returns an `%Esp32.Device{}` and every other function takes
  it. The port can be `:auto`, and the reset strategy comes from the pins given
  or the port's USB ids.
- `flash/4` header options default to `:keep` and reject unknown values.
  `:flash_size` also tells the loader the chip size.
- `Esp32.Image.parse/1` returns an `%Esp32.Image{}`.
- The ESP8266 is supported through the flasher stub only.

### Removed

- `Esp32.sync/1`, `Esp32.detect_chip/1`, `Esp32.parse_image/1`, `Esp32.GPIO` and
  the `:is_stub` and `:auto_reset` options.

### Fixed

- Responses are matched to their command and SLIP frames are no longer lost
  between reads, which could break stub start-up and mistake stale replies for
  answers.
- ROM errors were reported as success because status bytes were read at the
  wrong offset.
- The USB-JTAG/Serial reset is chosen by the opened port, and macOS port names
  are matched.
- Flashing through the ROM loader works on chips newer than the ESP32.
- `"keep"` no longer rewrites bootloader headers to DIO / 40 MHz / 4 MB.

## [0.1.0] - 2026-04-16

Initial release

### Added

- Support for entering bootloader mode for both UART and USB JTAG devices
- Parsing of firmware files to validate chip family
- Uploading stub loader and writing firmware .bin files to flash
- Tested on ESP32C3 and ESP32C6

[unreleased]: https://github.com/gworkman/esp32/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/gworkman/esp32/releases/tag/v0.1.0
