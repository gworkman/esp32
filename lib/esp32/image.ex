defmodule Esp32.Image do
  @moduledoc """
  Parser and validator for ESP32 firmware image files (.bin).
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
  Parses the firmware image and returns metadata and segments.
  """
  @spec parse(binary()) :: {:ok, map()} | {:error, any()}
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
