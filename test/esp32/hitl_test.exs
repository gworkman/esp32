defmodule Esp32.HITLTest do
  use ExUnit.Case

  @moduledoc """
  Hardware-in-the-loop tests; they need a connected ESP.

      ESP32_UART_PORT=/dev/ttyUSB0 mix test --include hitl
      ESP32_UART_PORT=ttyS1 ESP32_RESET_PIN=en ESP32_BOOT_PIN=io0 mix test --include hitl
      ESP32_TEST_BIN=firmware.bin mix test --include hitl
  """

  @moduletag :hitl

  defp connect_opts do
    case {System.get_env("ESP32_RESET_PIN"), System.get_env("ESP32_BOOT_PIN")} do
      {nil, _} -> []
      {_, nil} -> []
      {reset_pin, boot_pin} -> [reset_pin: reset_pin, boot_pin: boot_pin]
    end
  end

  defp port,
    do: System.get_env("ESP32_UART_PORT", "auto") |> then(&if(&1 == "auto", do: :auto, else: &1))

  test "connect, detect chip and read a register" do
    assert {:ok, esp} = Esp32.connect(port(), connect_opts())
    IO.puts("\n[HITL] chip: #{esp.chip}, stub: #{esp.stub?}")
    assert {:ok, _} = Esp32.read_reg(esp, 0x40001000)
    Esp32.close(esp)
  end

  test "flash a binary" do
    case System.get_env("ESP32_TEST_BIN") do
      nil ->
        IO.puts("\n[HITL] skipping flash test: ESP32_TEST_BIN not set")

      path ->
        {:ok, esp} = Esp32.connect(port(), connect_opts() ++ [baud_rate: 921_600])
        assert :ok = Esp32.flash_file(esp, path, 0x10000)
        Esp32.close(esp)
    end
  end
end
