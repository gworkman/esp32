defmodule Esp32.FakeUART do
  @moduledoc """
  Stands in for a `Circuits.UART` process in tests.

  Each written command is passed to the handler as `{op_id, payload}`; the frames
  it returns are queued for subsequent reads, as the SLIP framing would produce them.
  """

  use GenServer

  @ops %{
    flash_begin: 0x02,
    flash_data: 0x03,
    flash_end: 0x04,
    mem_begin: 0x05,
    mem_end: 0x06,
    mem_data: 0x07,
    sync: 0x08,
    write_reg: 0x09,
    read_reg: 0x0A,
    spi_attach: 0x0D,
    change_baudrate: 0x0F,
    spi_flash_md5: 0x13,
    get_security_info: 0x14,
    erase_flash: 0xD0
  }

  def start_link(handler \\ fn _ -> [] end), do: GenServer.start_link(__MODULE__, handler)

  @doc "Queues frames to be returned by the next reads."
  def push(pid, frames), do: GenServer.call(pid, {:push, frames})

  @doc "Commands written so far, oldest first."
  def writes(pid), do: GenServer.call(pid, :writes)

  @doc "Calls other than read/write/push, oldest first."
  def calls(pid), do: GenServer.call(pid, :calls)

  @doc "Builds a bootloader response packet for `op`."
  def response(op, data, value \\ 0) do
    <<0x01, Map.fetch!(@ops, op), byte_size(data)::little-16, value::little-32, data::binary>>
  end

  @impl true
  def init(handler), do: {:ok, %{handler: handler, queue: [], writes: [], calls: []}}

  @impl true
  def handle_call({:write, data, _timeout}, _from, state) do
    <<0x00, op, _size::little-16, _checksum::little-32, payload::binary>> = data
    frames = state.handler.({op, payload})

    {:reply, :ok,
     %{state | queue: state.queue ++ frames, writes: state.writes ++ [{op, payload}]}}
  end

  def handle_call({:read, _timeout}, _from, %{queue: [frame | rest]} = state) do
    {:reply, {:ok, frame}, %{state | queue: rest}}
  end

  def handle_call({:read, _timeout}, _from, state), do: {:reply, {:ok, <<>>}, state}

  def handle_call({:flush, _direction}, _from, state) do
    {:reply, :ok, %{state | queue: [], calls: state.calls ++ [:flush]}}
  end

  def handle_call({:push, frames}, _from, state) do
    {:reply, :ok, %{state | queue: state.queue ++ frames}}
  end

  def handle_call(:writes, _from, state), do: {:reply, state.writes, state}
  def handle_call(:calls, _from, state), do: {:reply, state.calls, state}
  def handle_call(:close, _from, state), do: {:reply, :ok, state}

  def handle_call(call, _from, state) do
    {:reply, :ok, %{state | calls: state.calls ++ [call]}}
  end
end
