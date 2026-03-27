defmodule Esp32.HITLTest do
  use ExUnit.Case

  @moduledoc """
  Hardware-In-The-Loop tests for ESP32 bootloader.
  These tests require an actual ESP32 connected to the system.

  To run these tests:
  mix test --include hitl

  You can configure the UART port and pins via environment variables:
  ESP32_UART_PORT=/dev/ttyUSB0 ESP32_EN_PIN=en_pin_name ESP32_IO0_PIN=io0_pin_name mix test --include hitl
  """

  @tag :hitl
  test "connect, sync, and detect chip" do
    uart_port = System.get_env("ESP32_UART_PORT", "/dev/ttyUSB0")
    en_pin = System.get_env("ESP32_EN_PIN", "en")
    io0_pin = System.get_env("ESP32_IO0_PIN", "io0")

    # Use auto_reset if the environment says so
    opts =
      if en_pin == "auto" do
        [auto_reset: true]
      else
        [en_pin: en_pin, io0_pin: io0_pin]
      end

    # Attempt connection
    assert {:ok, uart} = Esp32.connect(uart_port, opts ++ [use_stub: true])

    # Detect chip
    assert {:ok, chip} = Esp32.detect_chip(uart)
    IO.puts("\n[HITL] Detected Chip: #{chip}")

    # Read a known register
    assert {:ok, _} = Esp32.read_reg(uart, 0x40001000)

    # Cleanup
    Circuits.UART.close(uart)
  end

  @tag :hitl
  test "parse and flash a real binary (smoke test)" do
    # This test would require a valid bin file path in the environment
    bin_path = System.get_env("ESP32_TEST_BIN")

    if bin_path && File.exists?(bin_path) do
      uart_port = System.get_env("ESP32_UART_PORT", "/dev/ttyUSB0")
      en_pin = System.get_env("ESP32_EN_PIN", "en")
      io0_pin = System.get_env("ESP32_IO0_PIN", "io0")

      opts =
        if en_pin == "auto" do
          [auto_reset: true]
        else
          [en_pin: en_pin, io0_pin: io0_pin]
        end

      {:ok, uart} = Esp32.connect(uart_port, opts ++ [use_stub: true])

      # Flash to some offset (e.g., 0x10000)
      assert :ok = Esp32.flash_file(uart, bin_path, 0x10000, is_stub: true, reboot: false)

      Circuits.UART.close(uart)
    else
      IO.puts("\n[HITL] Skipping flash smoke test: ESP32_TEST_BIN not set or file not found")
    end
  end
end
