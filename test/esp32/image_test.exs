defmodule Esp32.ImageTest do
  use ExUnit.Case
  alias Esp32.Image

  test "parse/1 extracts metadata from image header" do
    # Header: Magic E9, Segments 1, Mode 2 (DIO), Size/Freq 0x10 (1MB/40MHz), Entry 0x40080000
    header = <<0xE9, 0x01, 0x02, 0x10, 0x00, 0x00, 0x08, 0x40>>
    # Extended Header: WP 0xEE, ChipID 0x0000 (ESP32), Hash 0
    ext_header =
      <<0xEE, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00>>

    # Segment: Offset 0x1000, Size 4, Data <<0x01, 0x02, 0x03, 0x04>>
    segment = <<0x00, 0x10, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04>>

    binary = header <> ext_header <> segment

    assert {:ok, metadata, _footer} = Image.parse(binary)
    assert metadata.segments_count == 1
    assert metadata.chip_id == :esp32
    assert metadata.entry_point == 0x40080000
    assert Enum.at(metadata.segments, 0).data == <<0x01, 0x02, 0x03, 0x04>>
  end

  test "verify_checksum/2 validates XOR sum" do
    segments = [%{data: <<0x01, 0x02>>}]
    # 0xEF ^ 0x01 ^ 0x02 = 0xEC
    assert Image.verify_checksum(%{segments: segments}, 0xEC) == true
  end
end
