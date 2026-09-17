defmodule Esp32 do
  @moduledoc """
  Serial bootloader client for ESP32-family chips, for Elixir and Nerves.

      {:ok, esp} = Esp32.connect("/dev/ttyUSB0", baud_rate: 921_600)
      :ok = Esp32.flash_file(esp, "firmware.bin", 0x10000)
      :ok = Esp32.close(esp)
  """

  import Bitwise

  alias Esp32.{Bootloader, Chip, Device, Image, Reset, UART}

  @default_baud 115_200
  @connect_attempts 7
  @sync_attempts 5
  # Espressif, Silicon Labs CP210x, QinHeng CH340, FTDI
  @bridge_vids [0x303A, 0x10C4, 0x1A86, 0x0403]

  @doc """
  Opens `port`, resets the chip into its bootloader, and prepares it for flashing.

  `port` is a serial device name, or `:auto` to use `find_port/0`.

  Options:
  - `:baud_rate` - speed used after connecting (default 115200)
  - `:initial_baud_rate` - speed used to connect and load the stub (default 115200)
  - `:use_stub` - load the flasher stub (default true)
  - `:reset` - reset the chip into the bootloader (default true)
  - `:reset_pin`, `:boot_pin` - `Circuits.GPIO` pins wired to EN and IO0; without
    them DTR/RTS are used
  - `:connect_attempts` - reset and sync attempts (default 7)
  """
  @spec connect(String.t() | :auto, keyword()) :: {:ok, Device.t()} | {:error, term()}
  def connect(port, opts \\ [])

  def connect(:auto, opts) do
    with {:ok, port} <- find_port(), do: connect(port, opts)
  end

  def connect(port, opts) when is_binary(port) do
    initial_baud = Keyword.get(opts, :initial_baud_rate, @default_baud)

    with {:ok, uart} <- UART.open(port, initial_baud) do
      device = %Device{uart: uart, port: port, baud: initial_baud}

      case establish(device, Reset.strategy(opts, UART.usb_ids(port)), opts) do
        {:ok, device} ->
          {:ok, device}

        {:error, reason} ->
          UART.close(uart)
          {:error, reason}
      end
    end
  end

  @doc false
  # Everything connect/2 does after the port is open
  def establish(device, strategy, opts) do
    attempts = Keyword.get(opts, :connect_attempts, @connect_attempts)

    with {:ok, stub_running?} <- enter_bootloader(device, strategy, opts, 0, attempts),
         {:ok, chip} <- Bootloader.detect_chip(device),
         device = %{device | chip: chip, stub?: stub_running?},
         {:ok, device} <- detect_usb_otg(device),
         {:ok, device} <- maybe_load_stub(device, Keyword.get(opts, :use_stub, true)) do
      maybe_change_baud(device, Keyword.get(opts, :baud_rate, device.baud))
    end
  end

  defp enter_bootloader(device, strategy, opts, attempt, attempts) when attempt < attempts do
    UART.flush(device.uart)

    with :ok <- Reset.run(strategy, device.uart, opts, attempt) do
      case try_sync(device, @sync_attempts) do
        {:ok, stub_running?} -> {:ok, stub_running?}
        {:error, _} -> enter_bootloader(device, strategy, opts, attempt + 1, attempts)
      end
    end
  end

  defp enter_bootloader(_device, _strategy, _opts, _attempt, _attempts),
    do: {:error, :sync_failed}

  defp try_sync(_device, 0), do: {:error, :sync_failed}

  defp try_sync(device, attempts) do
    UART.flush(device.uart)

    case Bootloader.sync(device) do
      {:ok, stub_running?} ->
        {:ok, stub_running?}

      {:error, _} ->
        Process.sleep(50)
        try_sync(device, attempts - 1)
    end
  end

  # Native USB-OTG limits block sizes; the ROM records which console it is using
  defp detect_usb_otg(device) do
    case Chip.usb_otg_check(device.chip) do
      nil ->
        {:ok, device}

      {reg, value} ->
        with {:ok, read} <- Bootloader.read_reg(device, reg) do
          {:ok, %{device | usb_otg?: (read &&& 0xFF) == value}}
        end
    end
  end

  defp maybe_load_stub(%{stub?: true} = device, _use_stub), do: {:ok, device}
  defp maybe_load_stub(device, false), do: {:ok, device}
  defp maybe_load_stub(device, true), do: Bootloader.load_stub(device)

  defp maybe_change_baud(%{baud: baud} = device, baud), do: {:ok, device}
  defp maybe_change_baud(device, baud), do: Bootloader.change_baud(device, baud)

  @doc "Closes the serial port."
  @spec close(Device.t()) :: :ok
  def close(%Device{uart: uart}), do: UART.close(uart)

  @doc "Finds the first serial port backed by an Espressif chip or a common USB-serial bridge."
  @spec find_port() :: {:ok, String.t()} | {:error, :no_port_found}
  def find_port do
    Circuits.UART.enumerate()
    |> Enum.filter(fn {_port, info} -> info[:vendor_id] in @bridge_vids end)
    |> Enum.map(fn {port, _info} -> port end)
    |> Enum.sort()
    |> case do
      [port | _] -> {:ok, port}
      [] -> {:error, :no_port_found}
    end
  end

  @doc """
  Writes `binary` to flash at `offset`.

  Options:
  - `:flash_mode`, `:flash_freq`, `:flash_size` - rewrite the header of a bootloader
    image, see `Esp32.Image.patch_header/3` (default `:keep`)
  - `:verify` - compare the flash MD5 afterwards (default true)
  - `:reboot` - reset the chip when done (default false)

  Images built for a different chip are refused; other data is written as is.
  """
  @spec flash(Device.t(), binary(), non_neg_integer(), keyword()) :: :ok | {:error, term()}
  def flash(%Device{} = device, binary, offset, opts \\ []) do
    with {:ok, binary} <- prepare_image(device, binary, offset, opts),
         :ok <- maybe_spi_attach(device),
         {:ok, block_size} <- Bootloader.flash_begin(device, byte_size(binary), offset),
         :ok <- write_blocks(device, binary, block_size),
         :ok <- maybe_verify(device, binary, offset, Keyword.get(opts, :verify, true)) do
      finish(device, Keyword.get(opts, :reboot, false))
    end
  end

  @doc "Reads `path` and writes it with `flash/4`."
  @spec flash_file(Device.t(), Path.t(), non_neg_integer(), keyword()) :: :ok | {:error, term()}
  def flash_file(device, path, offset, opts \\ []) do
    with {:ok, binary} <- File.read(path), do: flash(device, binary, offset, opts)
  end

  defp prepare_image(device, binary, offset, opts) do
    with {:ok, binary} <- maybe_patch_header(device, binary, offset, opts) do
      case Image.parse(binary) do
        {:ok, %Image{chip: chip}} when chip != device.chip and device.chip != :esp8266 ->
          {:error, {:wrong_chip, chip}}

        _ ->
          {:ok, binary}
      end
    end
  end

  defp maybe_patch_header(device, binary, offset, opts) do
    if offset == Chip.bootloader_offset(device.chip),
      do: Image.patch_header(binary, device.chip, opts),
      else: {:ok, binary}
  end

  defp maybe_spi_attach(%{stub?: true}), do: :ok
  defp maybe_spi_attach(device), do: Bootloader.spi_attach(device)

  defp write_blocks(device, binary, block_size) do
    binary
    |> pad(block_size)
    |> Bootloader.chunk(block_size)
    |> Enum.with_index()
    |> Bootloader.reduce_ok(fn {block, seq} -> Bootloader.flash_block(device, block, seq) end)
  end

  # The last block is padded with 0xFF, the value of erased flash
  defp pad(binary, block_size) do
    case rem(byte_size(binary), block_size) do
      0 -> binary
      used -> binary <> :binary.copy(<<0xFF>>, block_size - used)
    end
  end

  defp maybe_verify(_device, _binary, _offset, false), do: :ok
  defp maybe_verify(%{stub?: false, chip: :esp8266}, _binary, _offset, true), do: :ok

  defp maybe_verify(device, binary, offset, true) do
    with {:ok, digest} <- Bootloader.flash_md5(device, offset, byte_size(binary)) do
      if digest == :crypto.hash(:md5, binary), do: :ok, else: {:error, :verify_failed}
    end
  end

  # FLASH_END makes the ROM loader exit, so the ROM only gets it when rebooting
  defp finish(%{stub?: false}, false), do: :ok
  defp finish(device, reboot?), do: Bootloader.flash_end(device, reboot?)

  @doc "Erases the whole flash chip. Requires the flasher stub; may take up to two minutes."
  @spec erase(Device.t()) :: :ok | {:error, term()}
  def erase(%Device{} = device), do: Bootloader.erase_flash(device)

  @doc "Reads a 32-bit register."
  @spec read_reg(Device.t(), non_neg_integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def read_reg(%Device{} = device, address), do: Bootloader.read_reg(device, address)

  @doc "Writes a 32-bit register."
  @spec write_reg(Device.t(), non_neg_integer(), non_neg_integer()) :: :ok | {:error, term()}
  def write_reg(%Device{} = device, address, value),
    do: Bootloader.write_reg(device, address, value)
end
