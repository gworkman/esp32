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
      {:ok, 0x1B31506F} -> {:ok, :esp32c3} # Alternate C3 value
      {:ok, 0x2CE1606F} -> {:ok, :esp32c6}
      {:ok, 0xD631606F} -> {:ok, :esp32h2}
      {:ok, other} -> {:ok, {:unknown, other}}
      error -> error
    end
  end

  @doc """
  Begins a flash operation.
  """
  @spec flash_begin(pid(), integer(), integer(), integer(), integer()) :: :ok | {:error, any()}
  def flash_begin(uart, size_to_erase, num_packets, packet_size, offset) do
    data = <<
      size_to_erase::little-32,
      num_packets::little-32,
      packet_size::little-32,
      offset::little-32
    >>

    cmd = Protocol.build_command(:FLASH_BEGIN, 0, data)
    encoded = SLIP.encode(cmd)

    with :ok <- UART.write(uart, encoded),
         {:ok, response} <- UART.read_packet(uart, 5000), # Erase can take time
         {:ok, decoded} <- SLIP.decode(response),
         {:ok, _cmd_id, _val, resp_data} <- Protocol.parse_response(decoded),
         {:ok, _} <- Protocol.parse_status(resp_data) do
      :ok
    end
  end
end
