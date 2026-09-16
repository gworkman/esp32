defmodule Esp32.FakeUART do
  @moduledoc """
  Stands in for a `Circuits.UART` process in tests.

  Each written command is passed to the handler as `{op_id, payload}`; the frames
  it returns are queued for subsequent reads, as the SLIP framing would produce them.
  """

  use GenServer

  def start_link(handler \\ fn _ -> [] end), do: GenServer.start_link(__MODULE__, handler)

  @doc "Queues frames to be returned by the next reads."
  def push(pid, frames), do: GenServer.call(pid, {:push, frames})

  @doc "Commands written so far, oldest first."
  def writes(pid), do: GenServer.call(pid, :writes)

  @doc "Calls other than read/write/push, oldest first."
  def calls(pid), do: GenServer.call(pid, :calls)

  @doc "Builds a bootloader response packet for `op`."
  def response(op, data, value \\ 0) do
    <<0x01, Esp32.Protocol.command_id(op), byte_size(data)::little-16, value::little-32,
      data::binary>>
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
