# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- `Esp32.connect/2` returns an `%Esp32.Device{}`; every operation takes it instead
  of a UART pid. `Esp32.close/1` closes it.
- `Esp32.connect/2` takes `:auto` instead of `"auto"`, and derives the reset
  strategy from `:reset_pin`/`:boot_pin` and the port's USB ids; `:auto_reset` is gone.
- `flash/4` and `flash_file/4` drop `:is_stub`, default header options to `:keep`,
  reject unknown flash parameters, refuse images built for another chip, and verify
  the written data by MD5.
- `Esp32.Image.parse/1` returns `{:ok, %Esp32.Image{}}`.
- `reboot: true` now hard-resets the chip (DTR/RTS or the EN pin) instead of
  sending `FLASH_END`, which only re-entered the bootloader; `Esp32.reset/1`
  exposes the same reset.

### Removed

- `Esp32.sync/1`, `Esp32.detect_chip/1`, `Esp32.parse_image/1`, `Esp32.GPIO`.

### Fixed

- SLIP frames arriving in the same read as the previous response are no longer lost.
- Responses are matched to their command; all eight SYNC replies are consumed.
- Status bytes are located from the response data length rather than a stub flag.
- ROM loader flashing sends the extended FLASH_BEGIN parameters, waits for the erase,
  and no longer exits the loader after each write.
- Chip ids for C5, C61, P4, H21, H4, E22 and S31; bootloader offsets for C5/P4/H4;
  chip-specific flash frequency encodings; removed fabricated magic values.

## [0.1.0] - 2026-04-16

Initial release

### Added

- Support for entering bootloader mode for both UART and USB JTAG devices
- Parsing of firmware files to validate chip family
- Uploading stub loader and writing firmware .bin files to flash
- Tested on ESP32C3 and ESP32C6

[unreleased]: https://github.com/gworkman/esp32/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/gworkman/esp32/releases/tag/v0.1.0
