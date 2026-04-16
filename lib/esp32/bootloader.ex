defmodule Esp32.Bootloader do
  @moduledoc """
  High-level operations for the ESP32 serial bootloader.
  """

  alias Esp32.SLIP
  alias Esp32.Protocol
  alias Esp32.UART

  @doc """
  Sends the SYNC frame to the ESP32 and waits for a response.
  """
  @spec sync(pid()) :: :ok | {:error, any()}
  def sync(uart) do
    # 36 bytes: 0x07 0x07 0x12 0x20, followed by 32 x 0x55
    sync_payload = <<0x07, 0x07, 0x12, 0x20>> <> :binary.copy(<<0x55>>, 32)
    cmd = Protocol.build_command(:SYNC, 0, sync_payload)
    encoded = SLIP.encode(cmd)

    # Drain boot ROM garbage (sent at 74880 baud, appears as noise at 115200)
    UART.drain(uart)

    # Sending sync multiple times is often necessary
    do_sync(uart, encoded, 7)
  end

  defp do_sync(_uart, _encoded, 0), do: {:error, :sync_failed}

  defp do_sync(uart, encoded, attempts) do
    with :ok <- UART.write(uart, encoded),
         {:ok, response} <- UART.read_packet(uart, 500),
         {:ok, decoded} <- SLIP.decode(response),
         {:ok, _cmd_id, _val, data} <- Protocol.parse_response(decoded),
         {:ok, _} <- Protocol.parse_status(data) do
      :ok
    else
      _ ->
        UART.drain(uart)
        do_sync(uart, encoded, attempts - 1)
    end
  end

  @doc """
  Reads a 32-bit register from the ESP32.
  """
  @spec read_reg(pid(), integer(), boolean()) :: {:ok, integer()} | {:error, any()}
  def read_reg(uart, address, is_stub \\ true) do
    cmd = Protocol.build_command(:READ_REG, 0, <<address::little-32>>)
    encoded = SLIP.encode(cmd)

    with :ok <- UART.write(uart, encoded),
         {:ok, response} <- UART.read_packet(uart),
         {:ok, decoded} <- SLIP.decode(response),
         {:ok, _cmd_id, val, data} <- Protocol.parse_response(decoded),
         {:ok, _} <- Protocol.parse_status(data, is_stub) do
      {:ok, val}
    end
  end

  @doc """
  Detects the connected chip type by reading magic registers or security info.

  Uses the preferred `GET_SECURITY_INFO` command on newer chips and falls back
  to reading the magic register `0x40001000` for older chips.

  Set `is_stub` to `true` if the flasher stub is already running.
  """
  @spec detect_chip(pid(), boolean()) :: {:ok, atom()} | {:error, any()}
  def detect_chip(uart, is_stub \\ true) do
    # For newer chips (ESP32-C3, S3, C6, etc.), GET_SECURITY_INFO is the preferred method
    case get_chip_id(uart, is_stub) do
      {:ok, 0x00} -> {:ok, :esp32}
      {:ok, 0x02} -> {:ok, :esp32s2}
      {:ok, 0x05} -> {:ok, :esp32c3}
      {:ok, 0x09} -> {:ok, :esp32s3}
      {:ok, 0x0C} -> {:ok, :esp32c2} # 12
      {:ok, 0x0D} -> {:ok, :esp32c6} # 13
      {:ok, 0x10} -> {:ok, :esp32h2} # 16
      _ ->
        # Fallback to magic register for older chips (ESP8266, ESP32 ROM)
        case read_reg(uart, 0x40001000, is_stub) do
          {:ok, 0xFFF0C101} -> {:ok, :esp8266}
          {:ok, 0x00F01D83} -> {:ok, :esp32}
          {:ok, 0x000007C6} -> {:ok, :esp32s2}
          {:ok, 0x00000009} -> {:ok, :esp32s3}
          {:ok, 0x6F51306F} -> {:ok, :esp32c2}
          {:ok, 0x6921506F} -> {:ok, :esp32c3}
          # Alternate C3 magic values
          {:ok, 0x1B31506F} -> {:ok, :esp32c3}
          {:ok, 0x20120707} -> {:ok, :esp32c3}
          {:ok, 0x20121F07} -> {:ok, :esp32c3}
          {:ok, 0x2CE1606F} -> {:ok, :esp32c6}
          {:ok, 0x2CE0806F} -> {:ok, :esp32c6}
          {:ok, 0xD631606F} -> {:ok, :esp32h2}
          {:ok, other} -> {:ok, {:unknown, other}}
          error -> error
        end
    end
  end

  @doc """
  Reads security info to get the chip ID.
  """
  @spec get_chip_id(pid(), boolean()) :: {:ok, integer()} | {:error, any()}
  def get_chip_id(uart, is_stub \\ true) do
    cmd = Protocol.build_command(:GET_SECURITY_INFO, 0, <<>>)
    encoded = SLIP.encode(cmd)

    with :ok <- UART.write(uart, encoded),
         {:ok, response} <- UART.read_packet(uart),
         {:ok, decoded} <- SLIP.decode(response),
         {:ok, _cmd_id, _val, data} <- Protocol.parse_response(decoded),
         {:ok, status_data} <- Protocol.parse_status(data, is_stub) do
      # 20 bytes response format includes chip_id at offset 12
      # 16 bytes response format also has chip_id at offset 12
      if byte_size(status_data) >= 16 do
        <<_flags::little-32, _crypt::8, _purposes::binary-size(7), chip_id::little-32, _rest::binary>> = status_data
        {:ok, chip_id}
      else
        {:error, {:invalid_security_info_size, byte_size(status_data)}}
      end
    end
  end

  @doc """
  Changes the baud rate of the ESP32.

  The `new_baud` is the target speed. The `old_baud` is only required for some
  older ROM loaders but is generally recommended to be set to the current speed.

  Note: After this command returns successfully, the host UART must also be
  reconfigured to the new baud rate.
  """
  @spec change_baud(pid(), pos_integer(), pos_integer()) :: :ok | {:error, any()}
  def change_baud(uart, new_baud, old_baud \\ 0) do
    data = <<new_baud::little-32, old_baud::little-32>>
    cmd = Protocol.build_command(:CHANGE_BAUDRATE, 0, data)
    encoded = SLIP.encode(cmd)

    # Some stubs/ROMs don't send a response, or the response is sent at the new baud rate.
    # We send and then immediately switch on our side.
    with :ok <- UART.write(uart, encoded) do
      # Wait a tiny bit for the packet to leave the host buffer
      Process.sleep(50)
      :ok
    end
  end

  @doc """
  Begins a RAM download operation.

  This is used to upload code (like the flasher stub) to the ESP32's internal RAM.
  """
  @spec mem_begin(pid(), integer(), integer(), integer(), integer()) :: :ok | {:error, any()}
  def mem_begin(uart, size, num_blocks, block_size, offset) do
    data = <<
      size::little-32,
      num_blocks::little-32,
      block_size::little-32,
      offset::little-32
    >>

    cmd = Protocol.build_command(:MEM_BEGIN, 0, data)
    encoded = SLIP.encode(cmd)

    with :ok <- UART.write(uart, encoded),
         {:ok, response} <- UART.read_packet(uart),
         {:ok, decoded} <- SLIP.decode(response),
         {:ok, _cmd_id, _val, resp_data} <- Protocol.parse_response(decoded),
         {:ok, _} <- Protocol.parse_status(resp_data) do
      :ok
    end
  end

  @doc """
  Sends a block of data to RAM.

  The `seq` parameter is the sequence number of the block (starting from 0).
  """
  @spec mem_data(pid(), binary(), integer()) :: :ok | {:error, any()}
  def mem_data(uart, data, seq) do
    checksum = Protocol.calculate_checksum(data)

    payload = <<
      byte_size(data)::little-32,
      seq::little-32,
      0::little-32,
      0::little-32,
      data::binary
    >>

    cmd = Protocol.build_command(:MEM_DATA, checksum, payload)
    encoded = SLIP.encode(cmd)

    with :ok <- UART.write(uart, encoded),
         {:ok, response} <- UART.read_packet(uart),
         {:ok, decoded} <- SLIP.decode(response),
         {:ok, _cmd_id, _val, resp_data} <- Protocol.parse_response(decoded),
         {:ok, _} <- Protocol.parse_status(resp_data) do
      :ok
    end
  end

  @doc """
  Finishes RAM download and executes code at entry point.

  If `entry_point` is 0, it may have different meanings depending on the chip.
  """
  @spec mem_end(pid(), integer()) :: :ok | {:error, any()}
  def mem_end(uart, entry_point) do
    data = <<
      if(entry_point == 0, do: 1, else: 0)::little-32,
      entry_point::little-32
    >>

    cmd = Protocol.build_command(:MEM_END, 0, data)
    encoded = SLIP.encode(cmd)

    with :ok <- UART.write(uart, encoded),
         {:ok, response} <- UART.read_packet(uart),
         {:ok, decoded} <- SLIP.decode(response),
         {:ok, _cmd_id, _val, resp_data} <- Protocol.parse_response(decoded),
         {:ok, _} <- Protocol.parse_status(resp_data) do
      :ok
    end
  end

  @doc """
  Loads the flasher stub into RAM and starts it.

  The flasher stub is a small program that runs on the ESP32 and provides
  optimized flashing routines (e.g., compressed flashing, higher baud rates).

  It automatically finds the stub JSON file in `priv/stubs/` based on the
  `chip_family`.
  """
  @spec load_stub(pid(), atom()) :: :ok | {:error, any()}
  def load_stub(_uart, {:unknown, magic}),
    do: {:error, {:unsupported_chip, magic}}

  def load_stub(uart, chip_family) when is_atom(chip_family) do
    stub_path = Application.app_dir(:esp32, "priv/stubs/#{chip_family}.json")

    with {:ok, json} <- File.read(stub_path),
         {:ok, stub} <- Jason.decode(json) do
      # Upload text segment
      :ok = upload_segment(uart, Base.decode64!(stub["text"]), stub["text_start"])

      # Upload data segment if present
      if stub["data"] do
        :ok = upload_segment(uart, Base.decode64!(stub["data"]), stub["data_start"])
      end

      # Execute
      :ok = mem_end(uart, stub["entry"])

      # Wait for "OHAI" - the stub may take a moment to start
      wait_for_ohai(uart, 10)
    end
  end

  defp wait_for_ohai(_uart, 0), do: {:error, :stub_start_timeout}

  defp wait_for_ohai(uart, attempts) do
    case UART.read_packet(uart, 500) do
      {:ok, <<0xC0, "OHAI", 0xC0>>} ->
        :ok

      {:ok, _other} ->
        # Skip other packets (could be late responses or garbage) and keep waiting
        wait_for_ohai(uart, attempts - 1)

      {:error, :timeout} ->
        wait_for_ohai(uart, attempts - 1)

      error ->
        error
    end
  end

  defp upload_segment(uart, data, offset) do
    # 6144 bytes
    block_size = 0x1800
    num_blocks = div(byte_size(data) + block_size - 1, block_size)

    with :ok <- mem_begin(uart, byte_size(data), num_blocks, block_size, offset) do
      data
      |> chunk_binary(block_size)
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn {chunk, seq}, :ok ->
        case mem_data(uart, chunk, seq) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  @doc false
  def chunk_binary(<<>>, _size), do: []
  def chunk_binary(bin, size) when byte_size(bin) <= size, do: [bin]

  def chunk_binary(bin, size) do
    <<chunk::binary-size(size), rest::binary>> = bin
    [chunk | chunk_binary(rest, size)]
  end

  @doc """
  Attaches to SPI flash.

  Required before flash operations when using the ROM loader.
  Usually not needed when using the flasher stub.
  """
  @spec spi_attach(pid(), boolean()) :: :ok | {:error, any()}
  def spi_attach(uart, is_stub \\ false) do
    # 0 = default SPI flash interface
    cmd = Protocol.build_command(:SPI_ATTACH, 0, <<0::little-32, 0::little-32>>)
    encoded = SLIP.encode(cmd)

    with :ok <- UART.write(uart, encoded),
         {:ok, response} <- UART.read_packet(uart),
         {:ok, decoded} <- SLIP.decode(response),
         {:ok, _cmd_id, _val, resp_data} <- Protocol.parse_response(decoded),
         {:ok, _} <- Protocol.parse_status(resp_data, is_stub) do
      :ok
    end
  end

  @doc """
  Begins a flash operation.

  This command erases the required flash area. Erasing can take several seconds
  depending on the size.
  """
  @spec flash_begin(pid(), integer(), integer(), integer(), integer(), boolean()) ::
          :ok | {:error, any()}
  def flash_begin(uart, size_to_erase, num_packets, packet_size, offset, is_stub \\ false) do
    data = <<
      size_to_erase::little-32,
      num_packets::little-32,
      packet_size::little-32,
      offset::little-32
    >>

    cmd = Protocol.build_command(:FLASH_BEGIN, 0, data)
    encoded = SLIP.encode(cmd)

    with :ok <- UART.write(uart, encoded),
         # Erase can take time
         {:ok, response} <- UART.read_packet(uart, 5000),
         {:ok, decoded} <- SLIP.decode(response),
         {:ok, _cmd_id, _val, resp_data} <- Protocol.parse_response(decoded),
         {:ok, _} <- Protocol.parse_status(resp_data, is_stub) do
      :ok
    end
  end

  @doc """
  Sends a block of data to flash.

  The data is written to the flash memory at the location specified in `flash_begin`.
  The `seq` parameter is the sequence number of the packet.
  """
  @spec flash_data(pid(), binary(), integer(), boolean()) :: :ok | {:error, any()}
  def flash_data(uart, data, seq, is_stub \\ false) do
    checksum = Protocol.calculate_checksum(data)

    payload = <<
      byte_size(data)::little-32,
      seq::little-32,
      0::little-32,
      0::little-32,
      data::binary
    >>

    cmd = Protocol.build_command(:FLASH_DATA, checksum, payload)
    encoded = SLIP.encode(cmd)

    # At 115200 baud, 16KB takes ~1.4s on the wire. The response only arrives
    # after the ESP32 receives the full SLIP frame, so the read timeout must
    # account for serial transmission time of the encoded payload.
    timeout = max(3000, div(byte_size(encoded) * 12, 115) + 1000)

    with :ok <- UART.write(uart, encoded),
         {:ok, response} <- UART.read_packet(uart, timeout),
         {:ok, decoded} <- SLIP.decode(response),
         {:ok, _cmd_id, _val, resp_data} <- Protocol.parse_response(decoded),
         {:ok, _} <- Protocol.parse_status(resp_data, is_stub) do
      :ok
    end
  end

  @doc """
  Finishes flash operation.

  Optionally reboots the ESP32 after flashing is complete.
  """
  @spec flash_end(pid(), boolean(), boolean()) :: :ok | {:error, any()}
  def flash_end(uart, reboot \\ false, is_stub \\ false) do
    # 0 to reboot, 1 to run user code
    reboot_val = if reboot, do: 0, else: 1
    cmd = Protocol.build_command(:FLASH_END, 0, <<reboot_val::little-32>>)
    encoded = SLIP.encode(cmd)

    with :ok <- UART.write(uart, encoded),
         {:ok, response} <- UART.read_packet(uart),
         {:ok, decoded} <- SLIP.decode(response),
         {:ok, _cmd_id, _val, resp_data} <- Protocol.parse_response(decoded),
         {:ok, _} <- Protocol.parse_status(resp_data, is_stub) do
      :ok
    end
  end
end
