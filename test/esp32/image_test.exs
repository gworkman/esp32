defmodule Esp32.ImageTest do
  use ExUnit.Case, async: true
  alias Esp32.Image

  @data <<1, 2, 3, 4>>

  # 8-byte header, 16-byte extended header, one segment, padding, checksum, optional SHA256
  defp build(opts \\ []) do
    mode = Keyword.get(opts, :mode, 2)
    size_freq = Keyword.get(opts, :size_freq, 0x20)
    chip_id = Keyword.get(opts, :chip_id, 5)
    hash = if Keyword.get(opts, :hash, false), do: 1, else: 0

    header = <<0xE9, 1, mode, size_freq, 0x40080000::little-32>>
    ext = <<0xEE, 0, 0, 0, chip_id::little-16, 0::72, hash>>
    segment = <<0x1000::little-32, 4::little-32, @data::binary>>
    body = header <> ext <> segment

    image =
      body <> :binary.copy(<<0>>, 47 - byte_size(body)) <> <<Esp32.Protocol.checksum(@data)>>

    if hash == 1, do: image <> :crypto.hash(:sha256, image), else: image
  end

  describe "parse/1" do
    test "extracts header fields, segments and checksum" do
      assert {:ok, image} = Image.parse(build())

      assert %Image{
               chip: :esp32c3,
               flash_mode: 2,
               flash_size: 2,
               flash_freq: 0,
               entry_point: 0x40080000
             } = image

      assert image.segments == [%{offset: 0x1000, data: @data}]
      assert image.checksum == Esp32.Protocol.checksum(@data)
      assert image.checksum_ok?
      assert image.data_length == 48
      refute image.hash_appended?
    end

    test "flags a bad checksum and unknown chips" do
      <<head::binary-size(47), _>> = build(chip_id: 77)
      assert {:ok, %Image{checksum_ok?: false, chip: {:unknown, 77}}} = Image.parse(head <> <<0>>)
    end

    test "rejects non-images and truncated images" do
      assert {:error, :invalid_magic} = Image.parse(<<0xAA, 0x50, 1, 2>>)
      assert {:error, :truncated} = Image.parse(binary_part(build(), 0, 10))
      assert {:error, :invalid_segments} = Image.parse(binary_part(build(), 0, 30))
      assert {:error, :truncated} = Image.parse(binary_part(build(), 0, 40))
    end
  end

  describe "patch_header/3" do
    test "leaves the image alone when everything is :keep" do
      image = build()
      assert {:ok, ^image} = Image.patch_header(image, :esp32c3, [])

      assert {:ok, ^image} =
               Image.patch_header(image, :esp32c3,
                 flash_mode: :keep,
                 flash_freq: :keep,
                 flash_size: :keep
               )
    end

    test "leaves non-images alone" do
      assert {:ok, <<0xAA, 0x50>>} =
               Image.patch_header(<<0xAA, 0x50>>, :esp32c3, flash_mode: :dio)
    end

    test "rewrites mode, size and frequency for the chip" do
      assert {:ok, <<0xE9, 1, 0, 0x4F, _::binary>>} =
               Image.patch_header(build(), :esp32c3,
                 flash_mode: :qio,
                 flash_freq: "80m",
                 flash_size: "16MB"
               )

      assert {:ok, <<0xE9, 1, 2, 0x40, _::binary>>} =
               Image.patch_header(build(), :esp32c6, flash_freq: "80m", flash_size: "16MB")

      assert {:ok, <<0xE9, 1, 2, 0x2F, _::binary>>} =
               Image.patch_header(build(), :esp32c3, flash_freq: "80m")
    end

    test "rejects unknown values instead of guessing" do
      assert {:error, {:invalid_flash_mode, "dio"}} =
               Image.patch_header(build(), :esp32c3, flash_mode: "dio")

      assert {:error, {:invalid_flash_freq, "60m"}} =
               Image.patch_header(build(), :esp32c3, flash_freq: "60m")

      assert {:error, {:invalid_flash_size, "3MB"}} =
               Image.patch_header(build(), :esp32c3, flash_size: "3MB")
    end

    test "recomputes the SHA256 digest when one is appended" do
      assert {:ok, patched} = Image.patch_header(build(hash: true), :esp32c3, flash_mode: :qio)
      <<data::binary-size(48), digest::binary-size(32)>> = patched
      assert digest == :crypto.hash(:sha256, data)
      assert {:ok, %Image{flash_mode: 0, hash_appended?: true}} = Image.parse(patched)
    end
  end
end
