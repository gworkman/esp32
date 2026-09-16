defmodule Esp32.FakeUARTTest do
  use ExUnit.Case, async: true
  alias Esp32.FakeUART

  test "queues handler frames for reads and records writes" do
    {:ok, uart} = FakeUART.start_link(fn {0x0A, payload} -> [<<0x01, 0x0A, payload::binary>>] end)

    assert :ok = Circuits.UART.write(uart, <<0x00, 0x0A, 4::little-16, 0::little-32, 1, 2, 3, 4>>)
    assert {:ok, <<0x01, 0x0A, 1, 2, 3, 4>>} = Circuits.UART.read(uart, 100)
    assert {:ok, <<>>} = Circuits.UART.read(uart, 100)
    assert FakeUART.writes(uart) == [{0x0A, <<1, 2, 3, 4>>}]
  end

  test "flush drops queued frames and other calls are recorded" do
    {:ok, uart} = FakeUART.start_link()
    FakeUART.push(uart, ["OHAI"])

    assert :ok = Circuits.UART.flush(uart, :receive)
    assert {:ok, <<>>} = Circuits.UART.read(uart, 0)
    assert :ok = Circuits.UART.configure(uart, speed: 921_600)
    assert :ok = Circuits.UART.set_dtr(uart, true)
    assert FakeUART.calls(uart) == [:flush, {:configure, [speed: 921_600]}, {:set_dtr, true}]
  end

  test "response/3 builds a response packet" do
    assert FakeUART.response(:read_reg, <<0, 0>>, 0x1234) ==
             <<0x01, 0x0A, 2::little-16, 0x1234::little-32, 0, 0>>
  end
end
