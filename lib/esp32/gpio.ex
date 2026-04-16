defmodule Esp32.GPIO do
  @moduledoc """
  Hardware control for the ESP32 reset and strapping pins.
  """

  require Logger

  @doc """
  Resets the ESP32 into bootloader mode using manual GPIO control.

  This is typically used in Nerves devices where the ESP32 is connected directly
  to the host CPU's GPIO pins.

  The procedure is:
  1. Pull IO0 LOW (strapping pin to select bootloader mode)
  2. Toggle EN (reset) LOW for 100ms, then HIGH
  3. Wait 100ms for the chip to initialize the bootloader
  4. Pull IO0 HIGH to release the strapping pin

  `en_pin` and `io0_pin` are the GPIO pin names as recognized by `Circuits.GPIO`.
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
