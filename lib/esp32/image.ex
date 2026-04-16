defmodule Esp32.Image do
  @moduledoc """
  Parser and validator for ESP32 firmware image files (.bin).

  The ESP32 firmware image format consists of:
  - A main header (8 bytes) including a magic byte (0xE9)
  - An extended header (16 bytes) containing chip and revision info
  - One or more segments, each with a header (8 bytes) followed by data
  - A footer containing a checksum and optionally a SHA256 hash
  """

  import Bitwise

  @magic 0xE9

  @chip_ids %{
    0x0000 => :esp32,
    0x0002 => :esp32s2,
    0x0005 => :esp32c3,
    0x0009 => :esp32s3,
    0x000C => :esp32c2,
    0x000D => :esp32c6,
    0x0010 => :esp32h2,
    0x0012 => :esp32p4,
    0x0017 => :esp32c5
  }

  @doc """
  Parses the firmware image and returns metadata, segments, and the footer.

  The return value is `{:ok, metadata, footer}` where `metadata` contains the
  parsed headers and segments.
  """
  @spec parse(binary()) :: {:ok, map(), binary()} | {:error, any()}
  def parse(
        <<@magic, segments_count, flash_mode, size_freq, entry_point::little-32, rest::binary>>
      ) do
    flash_size = size_freq >>> 4 &&& 0x0F
    flash_freq = size_freq &&& 0x0F

    metadata = %{
      segments_count: segments_count,
      flash_mode: flash_mode,
      flash_size: flash_size,
      flash_freq: flash_freq,
      entry_point: entry_point
    }

    # Extended header starts at offset 8, but we already matched 8 bytes.
    # The extended header is 16 bytes.
    case parse_extended_header(rest, metadata) do
      {:ok, metadata_ext, rest_after_ext} ->
        case parse_segments(rest_after_ext, segments_count, []) do
          {:ok, segments, footer} ->
            metadata_final = Map.put(metadata_ext, :segments, segments)
            {:ok, metadata_final, footer}

          error ->
            error
        end

      error ->
        error
    end
  end

  def parse(_), do: {:error, :invalid_magic}

  defp parse_extended_header(
         <<wp_pin, _drive::binary-size(3), chip_id::little-16, _min_rev::little-16,
           _max_rev::little-16, _res::binary-size(5), hash_appended, rest::binary>>,
         metadata
       ) do
    metadata_ext =
      Map.merge(metadata, %{
        wp_pin: wp_pin,
        chip_id: @chip_ids[chip_id] || {:unknown, chip_id},
        hash_appended: hash_appended == 1
      })

    {:ok, metadata_ext, rest}
  end

  defp parse_extended_header(_, _), do: {:error, :invalid_extended_header}

  defp parse_segments(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}

  defp parse_segments(
         <<offset::little-32, size::little-32, data::binary-size(size), rest::binary>>,
         count,
         acc
       ) do
    parse_segments(rest, count - 1, [%{offset: offset, size: size, data: data} | acc])
  end

  defp parse_segments(_, _, _), do: {:error, :invalid_segments}

  @doc """
  Patches the image header with new flash parameters and updates the SHA256 hash if necessary.

  Options:
  - `:flash_mode` - "qio", "qout", "dio", "dout"
  - `:flash_freq` - "40m", "26m", "20m", "80m"
  - `:flash_size` - "1MB", "2MB", "4MB", "8MB", "16MB" (supports "32MB", "64MB", "128MB" on S3/S2)
  """
  @spec patch_header(binary(), atom(), keyword()) :: binary()
  def patch_header(binary, chip_family, opts) do
    if byte_size(binary) < 24 do
      binary
    else
      mode = Keyword.get(opts, :flash_mode)
      freq = Keyword.get(opts, :flash_freq)
      size = Keyword.get(opts, :flash_size)

      if is_nil(mode) and is_nil(freq) and is_nil(size) do
        binary
      else
        <<header::binary-size(2), current_mode, current_size_freq, rest::binary>> = binary

        new_mode = if mode, do: map_flash_mode(mode), else: current_mode

        new_freq =
          if freq,
            do: map_flash_freq(freq, chip_family),
            else: current_size_freq &&& 0x0F

        new_size =
          if size,
            do: map_flash_size(size, chip_family),
            else: current_size_freq &&& 0xF0

        new_size_freq = new_size ||| new_freq

        patched = <<header::binary, new_mode, new_size_freq, rest::binary>>

        # Check for SHA256 hash appended (flag at offset 23)
        if chip_family != :esp8266 and binary_part(patched, 23, 1) == <<1>> do
          update_sha256(patched)
        else
          patched
        end
      end
    end
  end

  defp map_flash_mode("qio"), do: 0
  defp map_flash_mode("qout"), do: 1
  defp map_flash_mode("dio"), do: 2
  defp map_flash_mode("dout"), do: 3
  defp map_flash_mode(_), do: 2

  defp map_flash_freq("40m", _), do: 0x0
  defp map_flash_freq("26m", _), do: 0x1
  defp map_flash_freq("20m", _), do: 0x2
  defp map_flash_freq("80m", _), do: 0xF
  defp map_flash_freq(_, _), do: 0x0

  defp map_flash_size("1MB", _), do: 0x00
  defp map_flash_size("2MB", _), do: 0x10
  defp map_flash_size("4MB", _), do: 0x20
  defp map_flash_size("8MB", _), do: 0x30
  defp map_flash_size("16MB", _), do: 0x40
  # S2/S3 specific
  defp map_flash_size("32MB", chip) when chip in [:esp32s2, :esp32s3], do: 0x50
  defp map_flash_size("64MB", chip) when chip in [:esp32s2, :esp32s3], do: 0x60
  defp map_flash_size("128MB", chip) when chip in [:esp32s2, :esp32s3], do: 0x70
  defp map_flash_size(_, _), do: 0x20

  defp update_sha256(binary) do
    # SHA256 is appended after the checksum footer.
    # The file size is a multiple of 16. The last 32 bytes is the SHA.
    # We need to find the segment data length to know where the hash starts.
    case parse(binary) do
      {:ok, metadata, _footer} ->
        # Calculate length up to the checksum
        # Segment format: offset(4), size(4), data(size)
        data_len =
          Enum.reduce(metadata.segments, 8 + 16, fn seg, acc ->
            acc + 8 + byte_size(seg.data)
          end)

        # Pad to multiple of 16 - 1
        padding_len = 15 - rem(data_len, 16)
        total_len_before_hash = data_len + padding_len + 1

        data_to_hash = binary_part(binary, 0, total_len_before_hash)
        new_hash = :crypto.hash(:sha256, data_to_hash)

        data_to_hash <> new_hash

      _ ->
        binary
    end
  end

  @doc """
  Verifies the checksum of the image segments.
  The checksum is XOR of all data bytes and seed 0xEF.
  """
  @spec verify_checksum(map(), byte()) :: boolean()
  def verify_checksum(%{segments: segments}, expected_checksum) do
    checksum =
      Enum.reduce(segments, 0xEF, fn segment, acc ->
        calculate_xor(segment.data, acc)
      end)

    checksum == expected_checksum
  end

  defp calculate_xor(<<byte, rest::binary>>, acc) do
    calculate_xor(rest, bxor(acc, byte))
  end

  defp calculate_xor(<<>>, acc), do: acc &&& 0xFF
end
