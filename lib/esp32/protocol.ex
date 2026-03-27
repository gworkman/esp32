defmodule Esp32.Protocol do
  @moduledoc """
  Definitions and packet building for the ESP32 bootloader protocol.
  """

  import Bitwise

  @commands %{
    FLASH_BEGIN: 0x02,
    FLASH_DATA: 0x03,
    FLASH_END: 0x04,
    MEM_BEGIN: 0x05,
    MEM_END: 0x06,
    MEM_DATA: 0x07,
    SYNC: 0x08,
    WRITE_REG: 0x09,
    READ_REG: 0x0A,
    SPI_SET_PARAMS: 0x0B,
    SPI_ATTACH: 0x0D,
    CHANGE_BAUDRATE: 0x0F,
    FLASH_DEFL_BEGIN: 0x10,
    FLASH_DEFL_DATA: 0x11,
    FLASH_DEFL_END: 0x12,
    SPI_FLASH_MD5: 0x13,
    GET_SECURITY_INFO: 0x14
  }

  @doc """
  Returns the command ID for a given command name.
  """
  @spec command_id(atom()) :: integer()
  def command_id(name), do: @commands[name]

  @doc """
  Calculates the checksum for a given binary data.
  """
  @spec calculate_checksum(binary()) :: integer()
  def calculate_checksum(data) do
    do_checksum(data, 0xEF)
  end

  defp do_checksum(<<byte, rest::binary>>, acc) do
    do_checksum(rest, bxor(acc, byte))
  end

  defp do_checksum(<<>>, acc), do: acc &&& 0xFF

  @doc """
  Builds a command packet.
  """
  @spec build_command(atom() | integer(), integer(), binary()) :: binary()
  def build_command(command, checksum, data) do
    cmd_id = if is_atom(command), do: command_id(command), else: command
    size = byte_size(data)

    <<
      0x00,
      cmd_id,
      size::little-16,
      checksum::little-32,
      data::binary
    >>
  end

  @doc """
  Parses a response packet.

  Returns `{:ok, command_id, value, data}` or `{:error, reason}`.
  """
  @spec parse_response(binary()) :: {:ok, integer(), integer(), binary()} | {:error, atom()}
  def parse_response(
        <<0x01, command_id, size::little-16, value::little-32, data::binary-size(size)>>
      ) do
    {:ok, command_id, value, data}
  end

  def parse_response(<<0x01, _::binary>>) do
    {:error, :incomplete_packet}
  end

  def parse_response(_) do
    {:error, :invalid_packet_format}
  end

  @doc """
  Extracts status and error from the response data.

  Options:
  - `is_stub`: If true, assumes 2 status bytes (Stub loader). If false, 4 status bytes (ROM loader).
  """
  @spec parse_status(binary(), boolean()) :: {:ok, binary()} | {:error, {integer(), integer()}}
  def parse_status(data, is_stub \\ false) do
    size = byte_size(data)
    status_len = if is_stub, do: 2, else: 4

    if size >= status_len do
      payload_size = size - status_len
      <<payload::binary-size(payload_size), status_bytes::binary>> = data

      {status, error} =
        case status_bytes do
          <<status, error, _reserved::16>> -> {status, error}
          <<status, error>> -> {status, error}
        end

      if status == 0 do
        {:ok, payload}
      else
        {:error, {status, error}}
      end
    else
      {:error, :insufficient_data}
    end
  end
end
