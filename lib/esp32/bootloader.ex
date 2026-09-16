defmodule Esp32.Bootloader do
  @moduledoc """
  Commands of the ESP serial bootloader, for both the ROM loader and the flasher stub.
  """

  alias Esp32.{Device, Protocol, UART}

  @default_timeout 3_000
  @max_response_reads 100

  @doc """
  Sends `op` and returns `{:ok, value, data}` once a matching, successful response arrives.

  Options: `:checksum` (0), `:timeout` (3000 ms), `:resp_data_len` (0).

  Errors: `{op, error_byte}` for a failed status, `{op, :short_response}`,
  `:timeout` when no frame arrives, `:no_response` when 100 frames arrive
  without a matching response.
  """
  @spec command(Device.t(), Protocol.op(), binary(), keyword()) ::
          {:ok, non_neg_integer(), binary()} | {:error, term()}
  def command(device, op, data \\ <<>>, opts \\ []) do
    with {:ok, value, resp} <- raw_command(device, op, data, opts) do
      case Protocol.check_status(resp, Keyword.get(opts, :resp_data_len, 0)) do
        {:ok, resp_data} -> {:ok, value, resp_data}
        {:error, {:status, error}} -> {:error, {op, error}}
        {:error, reason} -> {:error, {op, reason}}
      end
    end
  end

  # Sends the command and returns the matching response without checking its status
  defp raw_command(device, op, data, opts) do
    packet = Protocol.build_command(op, Keyword.get(opts, :checksum, 0), data)

    with :ok <- UART.write(device.uart, packet) do
      read_response(
        device,
        Protocol.command_id(op),
        Keyword.get(opts, :timeout, @default_timeout)
      )
    end
  end

  @doc false
  # Reads frames until a response for `op_id` (any response when nil) arrives
  def read_response(device, op_id, timeout, reads_left \\ @max_response_reads)
  def read_response(_device, _op_id, _timeout, 0), do: {:error, :no_response}

  def read_response(device, op_id, timeout, reads_left) do
    with {:ok, frame} <- UART.read_frame(device.uart, timeout) do
      case Protocol.parse_response(frame) do
        {:ok, ^op_id, value, data} -> {:ok, value, data}
        {:ok, _op, value, data} when is_nil(op_id) -> {:ok, value, data}
        _ -> read_response(device, op_id, timeout, reads_left - 1)
      end
    end
  end

  @spec read_reg(Device.t(), non_neg_integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def read_reg(device, addr) do
    with {:ok, value, _} <- command(device, :read_reg, <<addr::little-32>>), do: {:ok, value}
  end

  @spec write_reg(
          Device.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          :ok | {:error, term()}
  def write_reg(device, addr, value, mask \\ 0xFFFFFFFF, delay_us \\ 0) do
    data = <<addr::little-32, value::little-32, mask::little-32, delay_us::little-32>>
    with {:ok, _, _} <- command(device, :write_reg, data), do: :ok
  end

  @doc false
  def chunk(<<>>, _size), do: []
  def chunk(bin, size) when byte_size(bin) <= size, do: [bin]

  def chunk(bin, size) do
    <<head::binary-size(^size), rest::binary>> = bin
    [head | chunk(rest, size)]
  end

  @doc false
  # Applies `fun` to each item until one returns an error
  def reduce_ok(enum, fun) do
    Enum.reduce_while(enum, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
end
