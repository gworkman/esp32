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
  - `use_stub`: If true, load the flasher stub (default true)
  """
  @spec connect(String.t(), String.t() | :auto_reset, String.t() | nil, keyword()) :: {:ok, pid()} | {:error, any()}
  def connect(uart_port, en_pin, io0_pin, opts \\ []) do
    baud_rate = Keyword.get(opts, :baud_rate, 115200)
    use_stub = Keyword.get(opts, :use_stub, true)

    with {:ok, uart} <- UART.open(uart_port, baud_rate),
         :ok <- reset_into_bootloader(uart, en_pin, io0_pin),
         :ok <- Bootloader.sync(uart) do
      if use_stub do
        with {:ok, chip_family} <- Bootloader.detect_chip(uart),
             :ok <- Bootloader.load_stub(uart, chip_family) do
          {:ok, uart}
        end
      else
        {:ok, uart}
      end
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
  Parses an ESP32 firmware image (.bin).
  """
  defdelegate parse_image(binary), to: Esp32.Image, as: :parse

  @doc """
  Flashes a firmware image file (.bin) to the ESP32.

  This function reads the file from disk, performs a safety check to ensure
  it is a valid ESP32 image, and then flashes it.
  """
  @spec flash_file(pid(), String.t(), integer(), keyword()) :: :ok | {:error, any()}
  def flash_file(uart, path, offset, opts \\ []) do
    with {:ok, binary} <- File.read(path),
         {:ok, _metadata, _footer} <- parse_image(binary) do
      # Optional: could check if metadata.chip_id matches detected chip here
      flash(uart, binary, offset, opts)
    end
  end

  @doc """
  Flashes a binary file to the ESP32.

  Options:
  - `is_stub`: If true, assumes stub loader protocol (default true)
  - `reboot`: If true, reboots after flashing (default false)
  """
  @spec flash(pid(), binary(), integer(), keyword()) :: :ok | {:error, any()}
  def flash(uart, binary, offset, opts \\ []) do
    is_stub = Keyword.get(opts, :is_stub, true)
    # 16KB for stub, 1KB for ROM
    packet_size = if is_stub, do: 0x4000, else: 0x400

    num_packets = div(byte_size(binary) + packet_size - 1, packet_size)
    size_to_erase = byte_size(binary)

    with :ok <- Bootloader.flash_begin(uart, size_to_erase, num_packets, packet_size, offset, is_stub) do
      binary
      |> Bootloader.chunk_binary(packet_size)
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn {chunk, seq}, :ok ->
        case Bootloader.flash_data(uart, chunk, seq, is_stub) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
      |> case do
        :ok ->
          reboot = Keyword.get(opts, :reboot, false)
          Bootloader.flash_end(uart, reboot, is_stub)

        error ->
          error
      end
    end
  end
end
