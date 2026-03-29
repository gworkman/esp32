defmodule Esp32.UART do
  @moduledoc """
  Serial communication wrapper for ESP32 bootloader.
  """

  alias Circuits.UART

  @doc """
  Opens the UART port for communication with the ESP32.
  """
  @spec open(String.t(), pos_integer()) :: {:ok, pid()} | {:error, any()}
  def open(port, baud_rate \\ 115_200) do
    with {:ok, uart} <- UART.start_link() do
      case UART.open(uart, port, speed: baud_rate, active: false) do
        :ok -> {:ok, uart}
        error -> error
      end
    end
  end

  @doc """
  Writes data to the UART port.
  """
  @spec write(pid(), binary()) :: :ok | {:error, any()}
  def write(uart, data), do: UART.write(uart, data)

  @doc """
  Sets the DTR (Data Terminal Ready) signal.
  Note: True usually means asserted (0V on most USB-serial chips).
  """
  @spec set_dtr(pid(), boolean()) :: :ok | {:error, any()}
  def set_dtr(uart, val), do: UART.set_dtr(uart, val)

  @doc """
  Sets the RTS (Request To Send) signal.
  Note: True usually means asserted (0V on most USB-serial chips).
  """
  @spec set_rts(pid(), boolean()) :: :ok | {:error, any()}
  def set_rts(uart, val), do: UART.set_rts(uart, val)

  @doc """
  Performs the automatic reset sequence using DTR and RTS.
  This is used by many ESP32 devboards.

  Sequence:
  1. DTR=False, RTS=True  (IO0=1, EN=0 -> Reset)
  2. Wait 100ms
  3. DTR=True, RTS=False  (IO0=0, EN=1 -> Boot mode)
  4. Wait 50ms
  5. DTR=False            (IO0=1 -> Release)
  """
  @spec auto_reset(pid()) :: :ok | {:error, any()}
  def auto_reset(uart) do
    with :ok <- set_dtr(uart, false),
         :ok <- set_rts(uart, true),
         _ <- Process.sleep(100),
         :ok <- set_dtr(uart, true),
         :ok <- set_rts(uart, false),
         _ <- Process.sleep(50),
         :ok <- set_dtr(uart, false) do
      :ok
    end
  end

  @doc """
  Drains any pending data from the UART receive buffer.
  """
  @spec drain(pid(), pos_integer()) :: :ok
  def drain(uart, timeout \\ 100) do
    case UART.read(uart, timeout) do
      {:ok, <<>>} -> :ok
      {:ok, _} -> drain(uart, timeout)
      _ -> :ok
    end
  end

  @doc """
  Reads a SLIP-framed packet from the UART port.
  Waits for a complete frame delimited by 0xC0 start and end markers.
  """
  @spec read_packet(pid(), pos_integer()) :: {:ok, binary()} | {:error, any()}
  def read_packet(uart, timeout \\ 1000) do
    read_until_frame(uart, <<>>, timeout)
  end

  defp read_until_frame(uart, acc, timeout) do
    case UART.read(uart, timeout) do
      {:ok, <<>>} ->
        {:error, :timeout}

      {:ok, data} ->
        new_acc = acc <> data

        case find_frame(new_acc) do
          {:ok, frame} -> {:ok, frame}
          :incomplete -> read_until_frame(uart, new_acc, timeout)
        end

      error ->
        error
    end
  end

  # Finds a complete SLIP frame (0xC0 <content> 0xC0) in the accumulated data.
  # Skips any garbage before the first 0xC0 and any empty frames from
  # consecutive 0xC0 markers.
  defp find_frame(data) do
    case :binary.match(data, <<0xC0>>) do
      :nomatch ->
        :incomplete

      {pos, 1} ->
        after_start = pos + 1
        rest = binary_part(data, after_start, byte_size(data) - after_start)

        case :binary.match(rest, <<0xC0>>) do
          :nomatch ->
            :incomplete

          {0, 1} ->
            # Consecutive 0xC0 bytes (empty frame), skip and keep looking
            find_frame(rest)

          {end_pos, 1} ->
            content = binary_part(rest, 0, end_pos)
            {:ok, <<0xC0, content::binary, 0xC0>>}
        end
    end
  end
end
