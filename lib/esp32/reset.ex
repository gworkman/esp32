defmodule Esp32.Reset do
  @moduledoc """
  Sequences that reset an ESP into its serial bootloader.

  Development boards wire DTR/RTS to EN/IO0 (`classic/2`); chips with a built-in
  USB-JTAG/Serial peripheral need `usb_jtag_serial/1`; custom hardware can drive the
  pins directly with `gpio/2`.
  """

  alias Esp32.UART

  @usb_jtag_serial_ids {0x303A, 0x1001}

  @type strategy :: :none | :gpio | :usb_jtag_serial | :classic

  @doc "Picks the strategy from connect options and the port's USB vendor/product ids."
  @spec strategy(keyword(), {non_neg_integer(), non_neg_integer()} | nil) :: strategy()
  def strategy(opts, usb_ids) do
    cond do
      Keyword.get(opts, :reset, true) == false -> :none
      opts[:reset_pin] && opts[:boot_pin] -> :gpio
      usb_ids == @usb_jtag_serial_ids -> :usb_jtag_serial
      true -> :classic
    end
  end

  @doc "Runs `strategy`; odd attempts use a longer classic delay, as esptool does."
  @spec run(strategy(), pid(), keyword(), non_neg_integer()) :: :ok | {:error, term()}
  def run(:none, _uart, _opts, _attempt), do: :ok
  def run(:gpio, _uart, opts, _attempt), do: gpio(opts[:reset_pin], opts[:boot_pin])
  def run(:usb_jtag_serial, uart, _opts, _attempt), do: usb_jtag_serial(uart)

  def run(:classic, uart, _opts, attempt),
    do: classic(uart, if(rem(attempt, 2) == 0, do: 50, else: 550))

  @doc "Holds IO0 low while pulsing EN, using `Circuits.GPIO` pin names."
  @spec gpio(term(), term()) :: :ok | {:error, term()}
  def gpio(reset_pin, boot_pin) do
    with {:ok, en} <- Circuits.GPIO.open(reset_pin, :output),
         {:ok, io0} <- open_boot_pin(boot_pin, en) do
      try do
        Circuits.GPIO.write(io0, 0)
        Circuits.GPIO.write(en, 0)
        Process.sleep(100)
        Circuits.GPIO.write(en, 1)
        Process.sleep(100)
        Circuits.GPIO.write(io0, 1)
        :ok
      after
        Circuits.GPIO.close(en)
        Circuits.GPIO.close(io0)
      end
    end
  end

  defp open_boot_pin(boot_pin, en) do
    with {:error, reason} <- Circuits.GPIO.open(boot_pin, :output) do
      Circuits.GPIO.close(en)
      {:error, reason}
    end
  end

  @doc "DTR/RTS sequence for boards with the usual EN/IO0 transistor circuit."
  @spec classic(pid(), non_neg_integer()) :: :ok | {:error, term()}
  def classic(uart, delay_ms) do
    with :ok <- UART.set_dtr(uart, false),
         :ok <- UART.set_rts(uart, true),
         :ok <- sleep(100),
         :ok <- UART.set_dtr(uart, true),
         :ok <- UART.set_rts(uart, false),
         :ok <- sleep(delay_ms) do
      UART.set_dtr(uart, false)
    end
  end

  @doc "DTR/RTS sequence for the built-in USB-JTAG/Serial peripheral."
  @spec usb_jtag_serial(pid()) :: :ok | {:error, term()}
  def usb_jtag_serial(uart) do
    with :ok <- UART.set_rts(uart, false),
         :ok <- UART.set_dtr(uart, false),
         :ok <- sleep(100),
         :ok <- UART.set_dtr(uart, true),
         :ok <- UART.set_rts(uart, false),
         :ok <- sleep(100),
         :ok <- UART.set_rts(uart, true),
         :ok <- UART.set_dtr(uart, false),
         :ok <- UART.set_rts(uart, true),
         :ok <- sleep(100),
         :ok <- UART.set_dtr(uart, false) do
      UART.set_rts(uart, false)
    end
  end

  @doc "Resets the chip so it boots normally; USB-OTG ports need a longer pulse."
  @spec hard(strategy(), pid(), keyword(), boolean()) :: :ok | {:error, term()}
  def hard(:none, _uart, _opts, _usb_otg?), do: {:error, :no_reset_strategy}

  def hard(:gpio, _uart, opts, _usb_otg?) do
    with {:ok, en} <- Circuits.GPIO.open(opts[:reset_pin], :output) do
      try do
        Circuits.GPIO.write(en, 0)
        Process.sleep(100)
        Circuits.GPIO.write(en, 1)
        :ok
      after
        Circuits.GPIO.close(en)
      end
    end
  end

  def hard(_dtr_rts, uart, _opts, usb_otg?) do
    delay = if usb_otg?, do: 200, else: 100

    with :ok <- UART.set_rts(uart, true),
         :ok <- sleep(delay),
         :ok <- UART.set_rts(uart, false) do
      if usb_otg?, do: sleep(200), else: :ok
    end
  end

  defp sleep(ms), do: Process.sleep(ms)
end
