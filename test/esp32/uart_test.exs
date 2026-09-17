defmodule Esp32.UARTTest do
  use ExUnit.Case, async: true
  alias Esp32.UART

  @info %{vendor_id: 0x303A, product_id: 0x1001}

  test "usb_ids/2 finds ports listed by full path (macOS) or by name (Linux)" do
    assert UART.usb_ids("/dev/cu.usbmodem1", %{"/dev/cu.usbmodem1" => @info}) == {0x303A, 0x1001}
    assert UART.usb_ids("/dev/ttyUSB0", %{"ttyUSB0" => @info}) == {0x303A, 0x1001}
    assert UART.usb_ids("ttyUSB0", %{"ttyUSB0" => @info}) == {0x303A, 0x1001}
  end

  test "usb_ids/2 is nil for unknown or non-USB ports" do
    assert UART.usb_ids("/dev/ttyS0", %{"ttyS0" => %{}}) == nil
    assert UART.usb_ids("/dev/ttyS1", %{}) == nil
  end
end
