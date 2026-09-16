defmodule Esp32.Bootloader do
  @moduledoc """
  Commands of the ESP serial bootloader, for both the ROM loader and the flasher stub.
  """

  alias Esp32.{Chip, Device, Protocol, UART}

  @default_timeout 3_000
  @max_response_reads 100
  @sync_timeout 100
  @magic_reg 0x40001000

  @doc """
  Sends `op` and returns `{:ok, value, data}` once a matching, successful response arrives.

  Options: `:checksum` (0), `:timeout` (3000 ms), `:resp_data_len` (0).

  Error reasons, returned as `{:error, reason}`: `{op, error_byte}` for a
  failed status, `{op, :short_response}`, `:timeout` when no frame arrives,
  `:no_response` when 100 frames arrive without a matching response.
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

  @doc """
  Synchronizes with the loader. Returns whether the flasher stub is already running,
  which the ROM reveals by answering with a non-zero value.
  """
  @spec sync(Device.t()) :: {:ok, boolean()} | {:error, term()}
  def sync(device) do
    payload = <<0x07, 0x07, 0x12, 0x20>> <> :binary.copy(<<0x55>>, 32)

    with {:ok, first, _} <- command(device, :sync, payload, timeout: @sync_timeout),
         {:ok, rest} <- read_sync_replies(device, 7, []) do
      {:ok, Enum.all?([first | rest], &(&1 == 0))}
    end
  end

  defp read_sync_replies(_device, 0, values), do: {:ok, values}

  defp read_sync_replies(device, n, values) do
    with {:ok, value, _} <- read_response(device, nil, @sync_timeout) do
      read_sync_replies(device, n - 1, [value | values])
    end
  end

  @doc "Reads the security info block; `chip_id` is nil on chips that don't report one."
  @spec get_security_info(Device.t()) :: {:ok, map()} | {:error, term()}
  def get_security_info(device) do
    with {:ok, _value, resp} <- raw_command(device, :get_security_info, <<>>, []) do
      case {Protocol.check_status(resp, 20), Protocol.check_status(resp, 12)} do
        {{:ok,
          <<flags::little-32, crypt::8, purposes::binary-size(7), chip_id::little-32,
            api::little-32>>}, _} ->
          {:ok, security_info(flags, crypt, purposes, chip_id, api)}

        {_, {:ok, <<flags::little-32, crypt::8, purposes::binary-size(7)>>}} ->
          {:ok, security_info(flags, crypt, purposes, nil, nil)}

        {_, {:error, {:status, error}}} ->
          {:error, {:get_security_info, error}}

        {_, {:error, reason}} ->
          {:error, {:get_security_info, reason}}
      end
    end
  end

  defp security_info(flags, crypt, purposes, chip_id, api) do
    %{
      flags: flags,
      flash_crypt_cnt: crypt,
      key_purposes: :binary.bin_to_list(purposes),
      chip_id: chip_id,
      api_version: api
    }
  end

  @doc "Identifies the chip family from the security info, or the ROM magic register on older chips."
  @spec detect_chip(Device.t()) :: {:ok, Chip.name()} | {:error, term()}
  def detect_chip(device) do
    case get_security_info(device) do
      {:ok, %{chip_id: id}} when is_integer(id) ->
        lookup(Chip.from_id(id), {:unknown_chip_id, id})

      _ ->
        with {:ok, magic} <- read_reg(device, @magic_reg) do
          lookup(Chip.from_magic(magic), {:unknown_chip_magic, magic})
        end
    end
  end

  defp lookup(nil, error), do: {:error, error}
  defp lookup(chip, _error), do: {:ok, chip}
end
