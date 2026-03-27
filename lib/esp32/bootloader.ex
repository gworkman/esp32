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
    sync_payload = <<0x07, 0x07, 0x12, 0x20, List.duplicate(0x55, 32)::binary>>
    cmd = Protocol.build_command(:SYNC, 0, sync_payload)
    encoded = SLIP.encode(cmd)

    # Sending sync multiple times is often necessary
    do_sync(uart, encoded, 5)
  end

  defp do_sync(_uart, _encoded, 0), do: {:error, :sync_failed}

  defp do_sync(uart, encoded, attempts) do
    with :ok <- UART.write(uart, encoded),
         {:ok, response} <- UART.read_packet(uart, 200),
         {:ok, decoded} <- SLIP.decode(response),
         {:ok, _cmd_id, _val, data} <- Protocol.parse_response(decoded),
         {:ok, _} <- Protocol.parse_status(data) do
      :ok
    else
      _ -> do_sync(uart, encoded, attempts - 1)
    end
  end

  @doc """
  Reads a 32-bit register from the ESP32.
  """
  @spec read_reg(pid(), integer()) :: {:ok, integer()} | {:error, any()}
  def read_reg(uart, address) do
    cmd = Protocol.build_command(:READ_REG, 0, <<address::little-32>>)
    encoded = SLIP.encode(cmd)

    with :ok <- UART.write(uart, encoded),
         {:ok, response} <- UART.read_packet(uart),
         {:ok, decoded} <- SLIP.decode(response),
         {:ok, _cmd_id, val, data} <- Protocol.parse_response(decoded),
         {:ok, _} <- Protocol.parse_status(data) do
      {:ok, val}
    end
  end

  @doc """
  Detects the connected chip type by reading the magic register.
  """
  @spec detect_chip(pid()) :: {:ok, atom()} | {:error, any()}
  def detect_chip(uart) do
    # 0x40001000 is the common magic register address for chip detection
    case read_reg(uart, 0x40001000) do
      {:ok, 0xFFF0C101} -> {:ok, :esp8266}
      {:ok, 0x00F01D83} -> {:ok, :esp32}
      {:ok, 0x000007C6} -> {:ok, :esp32s2}
      {:ok, 0x00000009} -> {:ok, :esp32s3}
      {:ok, 0x6F51306F} -> {:ok, :esp32c2}
      {:ok, 0x6921506F} -> {:ok, :esp32c3}
      # Alternate C3 value
      {:ok, 0x1B31506F} -> {:ok, :esp32c3}
      {:ok, 0x2CE1606F} -> {:ok, :esp32c6}
      {:ok, 0xD631606F} -> {:ok, :esp32h2}
      {:ok, other} -> {:ok, {:unknown, other}}
      error -> error
    end
  end

  @doc """
  Begins a RAM download operation.
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
  """
  @spec load_stub(pid(), atom()) :: :ok | {:error, any()}
  def load_stub(uart, chip_family) do
    stub_path = "priv/stubs/#{chip_family}.json"

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

      # Wait for "OHAI"
      case UART.read_packet(uart, 500) do
        {:ok, <<0xC0, "OHAI", 0xC0>>} -> :ok
        {:ok, other} -> {:error, {:unexpected_response, other}}
        error -> error
      end
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
  Begins a flash operation.
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

    with :ok <- UART.write(uart, encoded),
         {:ok, response} <- UART.read_packet(uart),
         {:ok, decoded} <- SLIP.decode(response),
         {:ok, _cmd_id, _val, resp_data} <- Protocol.parse_response(decoded),
         {:ok, _} <- Protocol.parse_status(resp_data, is_stub) do
      :ok
    end
  end

  @doc """
  Finishes flash operation.
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
