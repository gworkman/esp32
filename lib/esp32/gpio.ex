defmodule Esp32.GPIO do
  @moduledoc """
  Hardware control for the ESP32 reset and strapping pins.
  """

  require Logger

  @doc """
  Resets the ESP32 and enters bootloader mode.

  The procedure is:
  1. Pull IO0 LOW (strapping pin for bootloader)
  2. Toggle EN (reset) LOW then HIGH
  3. Wait a brief moment for the device to start
  4. Release IO0
  """
  @spec enter_bootloader_mode(String.t(), String.t()) :: :ok | {:error, any()}
  def enter_bootloader_mode(en_pin, io0_pin) do
    with {:ok, en} <- Circuits.GPIO.open(en_pin, :output),
         {:ok, io0} <- Circuits.GPIO.open(io0_pin, :output) do
      try do
        # 1. IO0 LOW
        Circuits.GPIO.write(io0, 0)

        # 2. Reset (EN LOW -> HIGH)
        Circuits.GPIO.write(en, 0)
        Process.sleep(100)
        Circuits.GPIO.write(en, 1)

        # 3. Wait for bootloader to start
        Process.sleep(100)

        # 4. Release IO0 (can be HIGH or input, but typically HIGH)
        Circuits.GPIO.write(io0, 1)

        :ok
      after
        Circuits.GPIO.close(en)
        Circuits.GPIO.close(io0)
      end
    end
  end
end
