defmodule Esp32 do
  @moduledoc """
  ESP32 Serial Bootloader management library for Elixir and Nerves.
  """

  alias Esp32.GPIO
  alias Esp32.UART
  alias Esp32.Bootloader

  @doc """
  Connects to an ESP32 device, puts it in bootloader mode, and synchronizes.

  Options:
  - `baud_rate`: Baud rate for communication (default 115200)
  - `en_pin`: EN (reset) pin name, or :auto_reset for UART signal-based reset
  - `io0_pin`: IO0 (strapping) pin name (ignored if using :auto_reset)
  """
  @spec connect(String.t(), String.t() | :auto_reset, String.t() | nil, pos_integer()) :: {:ok, pid()} | {:error, any()}
  def connect(uart_port, en_pin, io0_pin, baud_rate \\ 115200) do
    with {:ok, uart} <- UART.open(uart_port, baud_rate),
         :ok <- reset_into_bootloader(uart, en_pin, io0_pin),
         :ok <- Bootloader.sync(uart) do
      {:ok, uart}
    end
  end

  defp reset_into_bootloader(uart, :auto_reset, _io0_pin), do: UART.auto_reset(uart)
  defp reset_into_bootloader(_uart, en_pin, io0_pin), do: GPIO.enter_bootloader_mode(en_pin, io0_pin)

  @doc """
  Synchronizes with the ESP32 bootloader.
  """
  defdelegate sync(uart), to: Bootloader

  @doc """
  Reads a 32-bit register from the ESP32.
  """
  defdelegate read_reg(uart, address), to: Bootloader

  @doc """
  Detects the connected ESP32 chip type.
  """
  defdelegate detect_chip(uart), to: Bootloader

  @doc """
  Flashes a binary file to the ESP32. (Incomplete implementation example).
  """
  @spec flash(pid(), binary(), integer()) :: :ok | {:error, any()}
  def flash(uart, binary, offset) do
    # Placeholder for actual flash loop logic.
    # Should implement flash_begin, chunking data, flash_data, and flash_end.
    packet_size = 1024
    num_packets = div(byte_size(binary) + packet_size - 1, packet_size)
    size_to_erase = byte_size(binary)

    with :ok <- Bootloader.flash_begin(uart, size_to_erase, num_packets, packet_size, offset) do
      # Loop through binary in chunks...
      :ok
    end
  end
end
