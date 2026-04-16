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
  - `:baud_rate` - Final baud rate for communication (default 115200)
  - `:initial_baud_rate` - Initial sync baud rate used for loading the flasher stub (default 115200)
  - `:use_stub` - If true, load the flasher stub (default true)
  - `:auto_reset` - If true, use UART DTR/RTS signals for reset (default false)
  - `:en_pin` - GPIO pin name for EN (reset) (required if not using :auto_reset)
  - `:io0_pin` - GPIO pin name for IO0 (boot mode) (required if not using :auto_reset)

  If `uart_port` is "auto", the library will attempt to find a connected ESP32.
  """
  @spec connect(String.t(), keyword()) :: {:ok, pid()} | {:error, any()}
  def connect("auto", opts) do
    case find_port() do
      {:ok, port} -> connect(port, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec connect(String.t(), keyword()) :: {:ok, pid()} | {:error, any()}
  def connect(uart_port, opts) do
    initial_baud = Keyword.get(opts, :initial_baud_rate, 115_200)
    final_baud = Keyword.get(opts, :baud_rate, initial_baud)
    use_stub = Keyword.get(opts, :use_stub, true)

    with {:ok, uart} <- UART.open(uart_port, initial_baud) do
      case do_connect(uart, opts, use_stub, initial_baud, final_baud) do
        {:ok, uart} -> {:ok, uart}
        error ->
          UART.close(uart)
          error
      end
    end
  end

  defp do_connect(uart, opts, use_stub, initial_baud, final_baud) do
    with :ok <- reset_into_bootloader(uart, opts),
         :ok <- Bootloader.sync(uart) do
      if use_stub do
        with {:ok, chip_family} <- Bootloader.detect_chip(uart, false),
             :ok <- Bootloader.load_stub(uart, chip_family) do
          # Switch baud rate if requested
          if final_baud != initial_baud do
            with :ok <- Bootloader.change_baud(uart, final_baud, initial_baud),
                 :ok <- UART.configure(uart, speed: final_baud) do
              UART.drain(uart)
              {:ok, uart}
            end
          else
            {:ok, uart}
          end
        end
      else
        {:ok, uart}
      end
    end
  end

  @doc """
  Attempts to find a connected ESP32 or USB-to-Serial bridge.

  Returns `{:ok, port}` if found, or `{:error, :no_port_found}`.
  """
  @spec find_port() :: {:ok, String.t()} | {:error, :no_port_found}
  def find_port do
    # Known Vendor/Product IDs
    # Espressif USB JTAG/Serial: 0x303A:0x1001
    # CP210x: 0x10C4:0xEA60
    # CH340: 0x1A86:0x7523
    # FTDI: 0x0403:0x6001
    Circuits.UART.enumerate()
    |> Enum.find(fn {_port, info} ->
      vid = Map.get(info, :vendor_id)
      pid = Map.get(info, :product_id)

      is_espressif?(vid, pid) or is_known_bridge?(vid, pid)
    end)
    |> case do
      {port, _info} -> {:ok, port}
      nil -> {:error, :no_port_found}
    end
  end

  defp is_espressif?(0x303A, _), do: true # Espressif VID
  defp is_espressif?(_, _), do: false

  defp is_known_bridge?(0x10C4, _), do: true # Silicon Labs CP210x VID
  defp is_known_bridge?(0x1A86, _), do: true # QinHeng CH340 VID
  defp is_known_bridge?(0x0403, _), do: true # FTDI VID
  defp is_known_bridge?(_, _), do: false

  defp reset_into_bootloader(uart, opts) do
    if Keyword.get(opts, :auto_reset, false) do
      # Use specialized USB reset if it looks like an Espressif built-in USB JTAG/Serial
      case Circuits.UART.enumerate() |> Enum.find(fn {_, info} -> Map.get(info, :vendor_id) == 0x303A end) do
        {_port, _info} -> UART.usb_jtag_serial_reset(uart)
        _ -> UART.auto_reset(uart)
      end
    else
      en_pin = Keyword.get(opts, :en_pin)
      io0_pin = Keyword.get(opts, :io0_pin)
      GPIO.enter_bootloader_mode(en_pin, io0_pin)
    end
  end

  @doc """
  Erases the entire SPI flash memory of the ESP device.

  Note: This command is only supported when the flasher stub is loaded.
  The operation can take up to 120 seconds depending on the flash chip.
  """
  @spec erase(pid(), keyword()) :: :ok | {:error, any()}
  def erase(uart, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 120_000)
    Bootloader.erase_flash(uart, timeout)
  end

  @doc """
  Synchronizes with the ESP32 bootloader.
  """
  @spec sync(pid()) :: :ok | {:error, any()}
  defdelegate sync(uart), to: Bootloader

  @doc """
  Reads a 32-bit register from the ESP32.
  """
  @spec read_reg(pid(), integer()) :: {:ok, integer()} | {:error, any()}
  defdelegate read_reg(uart, address), to: Bootloader

  @doc """
  Detects the connected ESP32 chip type.
  """
  @spec detect_chip(pid()) :: {:ok, atom()} | {:error, any()}
  defdelegate detect_chip(uart), to: Bootloader

  @doc """
  Parses an ESP32 firmware image (.bin).
  """
  @spec parse_image(binary()) :: {:ok, map(), binary()} | {:error, any()}
  defdelegate parse_image(binary), to: Esp32.Image, as: :parse

  @doc """
  Flashes a firmware image file (.bin) to the ESP32.

  This function reads the file from disk, performs a safety check to ensure
  it is a valid ESP32 image, and then flashes it.

  If the `offset` matches the chip's bootloader offset, the header is patched
  with the provided `:flash_mode`, `:flash_freq`, and `:flash_size` options.

  Options:
  - `:flash_mode` - "qio", "qout", "dio", "dout" (default: "keep")
  - `:flash_freq` - "40m", "26m", "20m", "80m" (default: "keep")
  - `:flash_size` - "1MB", "2MB", "4MB", "8MB", "16MB" (default: "keep")
  - `:is_stub` - Use stub protocol (default true)
  - `:reboot` - Reboot after flash (default false)
  """
  @spec flash_file(pid(), String.t(), integer(), keyword()) :: :ok | {:error, any()}

  def flash_file(uart, path, offset, opts \\ []) do
    with {:ok, binary} <- File.read(path),
         {:ok, _metadata, _footer} <- parse_image(binary),
         {:ok, chip_family} <- detect_chip(uart) do
      # If flashing to bootloader offset, patch the header
      final_binary =
        if offset == Bootloader.bootloader_offset(chip_family) do
          Esp32.Image.patch_header(binary, chip_family, opts)
        else
          binary
        end

      flash(uart, final_binary, offset, opts)
    end
  end

  @doc """
  Flashes a binary to the ESP32.

  Options:
  - `:is_stub` - Use stub protocol (default true)
  - `:reboot` - Reboot after flash (default false)
  """
  @spec flash(pid(), binary(), integer(), keyword()) :: :ok | {:error, any()}
  def flash(uart, binary, offset, opts \\ []) do
    is_stub = Keyword.get(opts, :is_stub, true)
    # 16KB for stub, 1KB for ROM
    packet_size = if is_stub, do: 0x4000, else: 0x400

    num_packets = div(byte_size(binary) + packet_size - 1, packet_size)
    size_to_erase = byte_size(binary)

    with :ok <- if(is_stub, do: :ok, else: Bootloader.spi_attach(uart, is_stub)),
         :ok <-
           Bootloader.flash_begin(uart, size_to_erase, num_packets, packet_size, offset, is_stub) do
      binary
      |> pad_and_chunk(packet_size)
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

  # Pads the binary to a multiple of block_size with 0xFF, then chunks it.
  # The ESP32 flash protocol requires the last block to be padded.
  defp pad_and_chunk(binary, block_size) do
    remainder = rem(byte_size(binary), block_size)

    padded =
      if remainder == 0,
        do: binary,
        else: binary <> :binary.copy(<<0xFF>>, block_size - remainder)

    padded
    |> Bootloader.chunk_binary(block_size)
    |> Enum.with_index()
  end
end
