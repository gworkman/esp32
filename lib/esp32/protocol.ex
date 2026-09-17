defmodule Esp32.Protocol do
  @moduledoc """
  Packet building and parsing for the ESP serial bootloader protocol.

  Request: `<<0x00, op, size::little-16, checksum::little-32, data::binary>>`.
  Response: `<<0x01, op, size::little-16, value::little-32, data::binary>>`, where
  `data` ends with two status bytes (ROM loaders append two more reserved bytes).
  """

  import Bitwise

  @commands %{
    flash_begin: 0x02,
    flash_data: 0x03,
    flash_end: 0x04,
    mem_begin: 0x05,
    mem_end: 0x06,
    mem_data: 0x07,
    sync: 0x08,
    write_reg: 0x09,
    read_reg: 0x0A,
    spi_set_params: 0x0B,
    spi_attach: 0x0D,
    change_baudrate: 0x0F,
    flash_defl_begin: 0x10,
    flash_defl_data: 0x11,
    flash_defl_end: 0x12,
    spi_flash_md5: 0x13,
    get_security_info: 0x14,
    erase_flash: 0xD0,
    erase_region: 0xD1,
    read_flash: 0xD2,
    run_user_code: 0xD3
  }

  @names Map.new(@commands, fn {name, id} -> {id, name} end)

  @type op :: atom()

  @spec command_id(op()) :: byte()
  def command_id(op), do: Map.fetch!(@commands, op)

  @spec command_name(byte()) :: op() | nil
  def command_name(id), do: Map.get(@names, id)

  @doc "XOR checksum over `data`, seeded with 0xEF."
  @spec checksum(binary()) :: byte()
  def checksum(data), do: for(<<byte <- data>>, reduce: 0xEF, do: (acc -> bxor(acc, byte)))

  @spec build_command(op(), non_neg_integer(), binary()) :: binary()
  def build_command(op, checksum, data) do
    <<0x00, command_id(op), byte_size(data)::little-16, checksum::little-32, data::binary>>
  end

  @doc "Splits a response frame; the size field is ignored because the stub under-reports it."
  @spec parse_response(term()) :: {:ok, byte(), non_neg_integer(), binary()} | :error
  def parse_response(<<0x01, op, _size::little-16, value::little-32, data::binary>>) do
    {:ok, op, value, data}
  end

  def parse_response(_), do: :error

  @doc """
  Checks the two status bytes that follow `resp_data_len` bytes of response data.

  Returns the response data on success or the error byte on failure.
  """
  @spec check_status(binary(), non_neg_integer()) ::
          {:ok, binary()} | {:error, {:status, byte()} | :short_response}
  def check_status(data, resp_data_len) do
    case data do
      <<resp::binary-size(^resp_data_len), 0, _error, _::binary>> -> {:ok, resp}
      <<_::binary-size(^resp_data_len), _status, error, _::binary>> -> {:error, {:status, error}}
      <<status, error, _::binary>> when status != 0 -> {:error, {:status, error}}
      _ -> {:error, :short_response}
    end
  end
end
