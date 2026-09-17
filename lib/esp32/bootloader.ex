defmodule Esp32.Bootloader do
  @moduledoc """
  Commands of the ESP serial bootloader, for both the ROM loader and the flasher stub.
  """

  alias Esp32.{Chip, Device, Protocol, UART}
  import Bitwise

  @default_timeout 3_000
  @max_response_reads 100
  @sync_timeout 100
  @magic_reg 0x40001000
  @mem_end_rom_timeout 200
  @chip_erase_timeout 120_000
  @erase_region_timeout_per_mb 30_000
  @md5_timeout_per_mb 8_000
  @write_block_attempts 3
  @rom_invalid_command 0x05

  @doc """
  Sends `op` and returns `{:ok, value, data}` once a matching, successful response arrives.

  Options: `:checksum` (0), `:timeout` (3000 ms), `:resp_data_len` (0).

  Error reasons, returned as `{:error, reason}`: `{op, error_byte}` for a
  failed status, `{op, :short_response}`, `:timeout` when no frame arrives,
  `:no_response` when 100 frames arrive without a matching response,
  `{:unsupported_command, op}` when the loader does not know the command.
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
        {:ok, ^op_id, value, data} ->
          {:ok, value, data}

        {:ok, _op, value, data} when is_nil(op_id) ->
          {:ok, value, data}

        {:ok, _op, _value, <<status, @rom_invalid_command, _::binary>>} when status != 0 ->
          unsupported_command(device, op_id)

        _ ->
          read_response(device, op_id, timeout, reads_left - 1)
      end
    end
  end

  # The ROM sends its invalid-command reply eight times; drain them before the next command
  defp unsupported_command(device, op_id) do
    Process.sleep(200)
    UART.flush(device.uart)
    {:error, {:unsupported_command, Protocol.command_name(op_id)}}
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
  Synchronizes with the loader and returns whether the flasher stub is already running:
  the ROM answers with non-zero values, the stub with zero.
  """
  @spec sync(Device.t()) :: {:ok, boolean()} | {:error, term()}
  def sync(device) do
    payload = <<0x07, 0x07, 0x12, 0x20>> <> :binary.copy(<<0x55>>, 32)

    with {:ok, first, _} <- raw_command(device, :sync, payload, timeout: @sync_timeout),
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

  @doc "RAM block size: USB-OTG limits transfers to 0x800 bytes."
  @spec ram_block_size(Device.t()) :: pos_integer()
  def ram_block_size(%{usb_otg?: true}), do: 0x800
  def ram_block_size(_device), do: 0x1800

  @spec mem_begin(
          Device.t(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          non_neg_integer()
        ) ::
          :ok | {:error, term()}
  def mem_begin(device, size, blocks, block_size, offset) do
    data = <<size::little-32, blocks::little-32, block_size::little-32, offset::little-32>>
    with {:ok, _, _} <- command(device, :mem_begin, data), do: :ok
  end

  @spec mem_data(Device.t(), binary(), non_neg_integer()) :: :ok | {:error, term()}
  def mem_data(device, data, seq) do
    payload =
      <<byte_size(data)::little-32, seq::little-32, 0::little-32, 0::little-32, data::binary>>

    with {:ok, _, _} <- command(device, :mem_data, payload, checksum: Protocol.checksum(data)),
         do: :ok
  end

  @doc "Leaves RAM download mode and jumps to `entry` (0 to stay in the loader)."
  @spec mem_end(Device.t(), non_neg_integer()) :: :ok | {:error, term()}
  def mem_end(device, entry) do
    no_entry = if entry == 0, do: 1, else: 0
    timeout = if device.stub?, do: @default_timeout, else: @mem_end_rom_timeout

    # The ROM may reset the UART before its reply is sent, so ROM failures are ignored
    case command(device, :mem_end, <<no_entry::little-32, entry::little-32>>, timeout: timeout) do
      {:ok, _, _} -> :ok
      {:error, _} when not device.stub? -> :ok
      error -> error
    end
  end

  @doc "Uploads the flasher stub for `device.chip` into RAM and starts it."
  @spec load_stub(Device.t()) :: {:ok, Device.t()} | {:error, term()}
  def load_stub(device) do
    with {:ok, stub} <- read_stub(device),
         :ok <- upload_segment(device, stub["text"], stub["text_start"]),
         :ok <- upload_segment(device, stub["data"], stub["data_start"]),
         :ok <- mem_end(device, stub["entry"]),
         :ok <- wait_for_ohai(device, @max_response_reads) do
      {:ok, %{device | stub?: true}}
    end
  end

  defp read_stub(device) do
    with {:ok, name} <- stub_name(device),
         {:ok, json} <- File.read(Application.app_dir(:esp32, "priv/stubs/#{name}.json")) do
      Jason.decode(json)
    end
  end

  # ESP32-P4 revisions below 3.0 need the rev1 stub
  defp stub_name(%{chip: :esp32p4} = device) do
    with {:ok, word} <- read_reg(device, 0x5012D04C) do
      major = (word >>> 23 &&& 1) <<< 2 ||| (word >>> 4 &&& 0x03)
      minor = word &&& 0x0F
      {:ok, if(major * 100 + minor < 300, do: "esp32p4-rev1", else: "esp32p4")}
    end
  end

  defp stub_name(device) do
    case Chip.stub(device.chip) do
      nil -> {:error, {:no_stub, device.chip}}
      name -> {:ok, name}
    end
  end

  defp upload_segment(_device, nil, _offset), do: :ok

  defp upload_segment(device, encoded, offset) do
    data = Base.decode64!(encoded)
    block_size = ram_block_size(device)
    blocks = chunk(data, block_size)

    with :ok <- mem_begin(device, byte_size(data), length(blocks), block_size, offset) do
      blocks
      |> Enum.with_index()
      |> reduce_ok(fn {block, seq} -> mem_data(device, block, seq) end)
    end
  end

  defp wait_for_ohai(_device, 0), do: {:error, :stub_start_failed}

  defp wait_for_ohai(device, reads_left) do
    case UART.read_frame(device.uart, @default_timeout) do
      {:ok, "OHAI"} -> :ok
      {:ok, <<0x01, _::binary>>} -> wait_for_ohai(device, reads_left - 1)
      {:ok, other} -> {:error, {:stub_start_failed, other}}
      error -> error
    end
  end

  @doc "Switches the device to `baud`, then the host UART."
  @spec change_baud(Device.t(), pos_integer()) :: {:ok, Device.t()} | {:error, term()}
  def change_baud(device, baud) do
    with {:ok, data} <- change_baud_params(device, baud),
         {:ok, _, _} <- command(device, :change_baudrate, data),
         :ok <- UART.set_baud(device.uart, baud) do
      Process.sleep(50)
      UART.flush(device.uart)
      {:ok, %{device | baud: baud}}
    end
  end

  defp change_baud_params(%{stub?: true, baud: current}, baud),
    do: {:ok, <<baud::little-32, current::little-32>>}

  # The ESP32 ROM derives its UART clock from a drifting calibration, so the request is pre-scaled
  defp change_baud_params(%{chip: :esp32} = device, baud) do
    with {:ok, cali} <- read_reg(device, 0x3FF5F06C),
         {:ok, efuse} <- read_reg(device, 0x3FF5A010) do
      rom_freq = (cali >>> 7 &&& 0x01FFFFFF) * 15625 * (efuse &&& 0xFF) / 40
      valid_freq = if rom_freq > 33_000_000, do: 40_000_000, else: 26_000_000
      {:ok, <<trunc(baud * rom_freq / valid_freq)::little-32, 0::little-32>>}
    end
  end

  defp change_baud_params(_device, baud), do: {:ok, <<baud::little-32, 0::little-32>>}

  @doc "Flash write block size: 0x4000 for the stub (0x800 over USB-OTG), 0x400 for the ROM."
  @spec flash_block_size(Device.t()) :: pos_integer()
  def flash_block_size(%{stub?: true, usb_otg?: true}), do: 0x800
  def flash_block_size(%{stub?: true}), do: 0x4000
  def flash_block_size(_device), do: 0x400

  @doc "Attaches the SPI flash. Needed on the ROM loader; the stub does this itself."
  @spec spi_attach(Device.t()) :: :ok | {:error, term()}
  def spi_attach(device) do
    data = if device.stub?, do: <<0::little-32>>, else: <<0::little-32, 0::little-32>>
    with {:ok, _, _} <- command(device, :spi_attach, data), do: :ok
  end

  @doc "Starts a flash write of `size` bytes at `offset`; the ROM erases the region up front."
  @spec flash_begin(Device.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, pos_integer()} | {:error, term()}
  def flash_begin(device, size, offset) do
    block_size = flash_block_size(device)
    blocks = div(size + block_size - 1, block_size)
    params = <<size::little-32, blocks::little-32, block_size::little-32, offset::little-32>>

    params =
      if device.stub? or Chip.rom_extended_flash_begin?(device.chip),
        do: params <> <<0::little-32>>,
        else: params

    timeout =
      if device.stub?,
        do: @default_timeout,
        else: timeout_per_mb(@erase_region_timeout_per_mb, size)

    with {:ok, _, _} <- command(device, :flash_begin, params, timeout: timeout),
         do: {:ok, block_size}
  end

  @doc "Writes block `seq`, retrying up to three times."
  @spec flash_block(Device.t(), binary(), non_neg_integer()) :: :ok | {:error, term()}
  def flash_block(device, data, seq, attempts \\ @write_block_attempts) do
    payload =
      <<byte_size(data)::little-32, seq::little-32, 0::little-32, 0::little-32, data::binary>>

    timeout = @default_timeout + div(byte_size(data) * 20_000, device.baud)

    case command(device, :flash_data, payload,
           checksum: Protocol.checksum(data),
           timeout: timeout
         ) do
      {:ok, _, _} -> :ok
      {:error, _} when attempts > 1 -> flash_block(device, data, seq, attempts - 1)
      error -> error
    end
  end

  @doc "Leaves flash mode; `reboot?` resets the chip instead of running the loader."
  @spec flash_end(Device.t(), boolean()) :: :ok | {:error, term()}
  def flash_end(device, reboot?) do
    run_user_code = if reboot?, do: 0, else: 1
    with {:ok, _, _} <- command(device, :flash_end, <<run_user_code::little-32>>), do: :ok
  end

  @doc "MD5 digest of `size` bytes of flash at `offset`."
  @spec flash_md5(Device.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, term()}
  def flash_md5(device, offset, size) do
    data = <<offset::little-32, size::little-32, 0::little-32, 0::little-32>>
    resp_len = if device.stub?, do: 16, else: 32
    opts = [resp_data_len: resp_len, timeout: timeout_per_mb(@md5_timeout_per_mb, size)]

    with {:ok, _, digest} <- command(device, :spi_flash_md5, data, opts) do
      if device.stub?, do: {:ok, digest}, else: decode_hex(digest)
    end
  end

  defp decode_hex(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, digest} -> {:ok, digest}
      :error -> {:error, {:spi_flash_md5, :invalid_response}}
    end
  end

  @doc "Erases the whole flash chip (stub only)."
  @spec erase_flash(Device.t()) :: :ok | {:error, term()}
  def erase_flash(%{stub?: false}), do: {:error, :stub_required}

  def erase_flash(device) do
    with {:ok, _, _} <- command(device, :erase_flash, <<>>, timeout: @chip_erase_timeout), do: :ok
  end

  defp timeout_per_mb(ms_per_mb, size),
    do: max(@default_timeout, div(ms_per_mb * size, 1_000_000))
end
