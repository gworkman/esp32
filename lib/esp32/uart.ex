defmodule Esp32.UART do
  @moduledoc """
  Serial transport for the bootloader: a `Circuits.UART` opened with SLIP framing,
  so reads yield whole decoded frames.
  """

  @spec open(String.t(), pos_integer()) :: {:ok, pid()} | {:error, term()}
  def open(port, baud) do
    {:ok, pid} = Circuits.UART.start_link()

    case Circuits.UART.open(pid, port, speed: baud, active: false, framing: Esp32.SLIP) do
      :ok ->
        {:ok, pid}

      {:error, reason} ->
        GenServer.stop(pid)
        {:error, reason}
    end
  end

  @spec close(pid()) :: :ok
  def close(pid) do
    Circuits.UART.close(pid)
    GenServer.stop(pid)
  end

  @doc "Writes one packet; the framing adds the SLIP delimiters and escapes."
  @spec write(pid(), binary()) :: :ok | {:error, term()}
  def write(pid, packet), do: Circuits.UART.write(pid, packet)

  @doc "Reads the next decoded frame."
  @spec read_frame(pid(), non_neg_integer()) :: {:ok, term()} | {:error, term()}
  def read_frame(pid, timeout) do
    case Circuits.UART.read(pid, timeout) do
      {:ok, <<>>} -> {:error, :timeout}
      other -> other
    end
  end

  @doc "Drops pending input, including frames Circuits.UART has already queued."
  @spec flush(pid()) :: :ok
  def flush(pid) do
    Circuits.UART.flush(pid, :receive)
    drain(pid)
  end

  defp drain(pid) do
    case Circuits.UART.read(pid, 0) do
      {:ok, <<>>} -> :ok
      {:ok, _frame} -> drain(pid)
      _ -> :ok
    end
  end

  @spec set_baud(pid(), pos_integer()) :: :ok | {:error, term()}
  def set_baud(pid, baud), do: Circuits.UART.configure(pid, speed: baud)

  @spec set_dtr(pid(), boolean()) :: :ok | {:error, term()}
  def set_dtr(pid, value), do: Circuits.UART.set_dtr(pid, value)

  @spec set_rts(pid(), boolean()) :: :ok | {:error, term()}
  def set_rts(pid, value), do: Circuits.UART.set_rts(pid, value)

  @doc "USB vendor and product id of `port`, if it is a USB device."
  @spec usb_ids(String.t()) :: {non_neg_integer(), non_neg_integer()} | nil
  def usb_ids(port) do
    case Circuits.UART.enumerate()[Path.basename(port)] do
      %{vendor_id: vid, product_id: pid} -> {vid, pid}
      _ -> nil
    end
  end
end
