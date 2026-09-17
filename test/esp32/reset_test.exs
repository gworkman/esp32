defmodule Esp32.ResetTest do
  use ExUnit.Case, async: true
  alias Esp32.{FakeUART, Reset}

  describe "strategy/2" do
    test "reset: false disables reset" do
      assert Reset.strategy([reset: false], {0x303A, 0x1001}) == :none
    end

    test "GPIO pins select the GPIO sequence" do
      assert Reset.strategy([reset_pin: "en", boot_pin: "io0"], nil) == :gpio
    end

    test "the USB-JTAG/Serial peripheral needs its own sequence" do
      assert Reset.strategy([], {0x303A, 0x1001}) == :usb_jtag_serial
    end

    test "everything else uses the classic DTR/RTS sequence" do
      assert Reset.strategy([], {0x10C4, 0xEA60}) == :classic
      assert Reset.strategy([], {0x303A, 0x4001}) == :classic
      assert Reset.strategy([], nil) == :classic
      assert Reset.strategy([reset_pin: "en"], nil) == :classic
    end
  end

  describe "run/4" do
    test ":none does nothing" do
      {:ok, uart} = FakeUART.start_link()
      assert :ok = Reset.run(:none, uart, [], 0)
      assert FakeUART.calls(uart) == []
    end

    test ":classic toggles DTR/RTS, alternating the delay between attempts" do
      {:ok, uart} = FakeUART.start_link()
      {short, _} = :timer.tc(fn -> assert :ok = Reset.run(:classic, uart, [], 0) end)
      {long, _} = :timer.tc(fn -> assert :ok = Reset.run(:classic, uart, [], 1) end)

      assert Enum.take(FakeUART.calls(uart), 5) ==
               [
                 {:set_dtr, false},
                 {:set_rts, true},
                 {:set_dtr, true},
                 {:set_rts, false},
                 {:set_dtr, false}
               ]

      assert long - short > 400_000
    end

    test ":usb_jtag_serial ends with both lines released" do
      {:ok, uart} = FakeUART.start_link()
      assert :ok = Reset.run(:usb_jtag_serial, uart, [], 0)
      assert Enum.take(FakeUART.calls(uart), -2) == [{:set_dtr, false}, {:set_rts, false}]
    end
  end

  describe "hard/4" do
    test ":none has no reset strategy" do
      {:ok, uart} = FakeUART.start_link()
      assert {:error, :no_reset_strategy} = Reset.hard(:none, uart, [], false)
    end

    test ":classic pulses RTS" do
      {:ok, uart} = FakeUART.start_link()
      assert :ok = Reset.hard(:classic, uart, [], false)
      assert FakeUART.calls(uart) == [{:set_rts, true}, {:set_rts, false}]
    end

    test ":usb_jtag_serial pulses RTS with a longer delay" do
      {:ok, uart} = FakeUART.start_link()
      {elapsed, _} = :timer.tc(fn -> Reset.hard(:usb_jtag_serial, uart, [], true) end)

      assert FakeUART.calls(uart) == [{:set_rts, true}, {:set_rts, false}]
      assert elapsed >= 350_000
    end
  end
end
