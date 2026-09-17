defmodule Esp32.Image do
  @moduledoc """
  Parser for ESP32-family application images.

  An image is an 8-byte header, a 16-byte extended header, the segments, padding
  and a checksum byte closing a 16-byte boundary, then an optional SHA256 digest.
  ESP8266 images have no extended header and are not supported.
  """

  import Bitwise

  alias Esp32.{Chip, Protocol}

  @magic 0xE9
  @flash_modes %{qio: 0, qout: 1, dio: 2, dout: 3}
  @digest_length 32

  @type t :: %__MODULE__{
          entry_point: non_neg_integer(),
          flash_mode: 0..3,
          flash_freq: 0..15,
          flash_size: 0..15,
          chip: Chip.name() | {:unknown, non_neg_integer()},
          hash_appended?: boolean(),
          segments: [%{offset: non_neg_integer(), data: binary()}],
          checksum: byte(),
          checksum_ok?: boolean(),
          data_length: pos_integer()
        }

  defstruct [
    :entry_point,
    :flash_mode,
    :flash_freq,
    :flash_size,
    :chip,
    :segments,
    :checksum,
    :data_length,
    hash_appended?: false,
    checksum_ok?: false
  ]

  @spec parse(binary()) :: {:ok, t()} | {:error, :invalid_magic | :invalid_segments | :truncated}
  def parse(
        <<@magic, count, mode, size_freq, entry::little-32, ext::binary-size(16), rest::binary>> =
          binary
      ) do
    <<_wp_pin, _drive::binary-size(3), chip_id::little-16, _::binary-size(9), hash_appended>> =
      ext

    with {:ok, segments, rest} <- parse_segments(rest, count, []) do
      # The checksum byte is the last byte of the 16-byte block following the segments
      data_length = align16(byte_size(binary) - byte_size(rest) + 1)

      if byte_size(binary) < data_length do
        {:error, :truncated}
      else
        checksum = :binary.at(binary, data_length - 1)

        {:ok,
         %__MODULE__{
           entry_point: entry,
           flash_mode: mode,
           flash_size: size_freq >>> 4,
           flash_freq: size_freq &&& 0x0F,
           chip: Chip.from_id(chip_id) || {:unknown, chip_id},
           hash_appended?: hash_appended == 1,
           segments: segments,
           checksum: checksum,
           checksum_ok?: checksum == segment_checksum(segments),
           data_length: data_length
         }}
      end
    end
  end

  def parse(_binary), do: {:error, :invalid_magic}

  defp parse_segments(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}

  defp parse_segments(
         <<offset::little-32, size::little-32, data::binary-size(size), rest::binary>>,
         count,
         acc
       ) do
    parse_segments(rest, count - 1, [%{offset: offset, data: data} | acc])
  end

  defp parse_segments(_rest, _count, _acc), do: {:error, :invalid_segments}

  defp align16(n), do: div(n + 15, 16) * 16

  defp segment_checksum(segments) do
    segments |> Enum.map(& &1.data) |> IO.iodata_to_binary() |> Protocol.checksum()
  end

  @doc """
  Rewrites the flash mode, size and frequency bytes of a bootloader image.

  Options `:flash_mode` (`:qio | :qout | :dio | :dout`), `:flash_freq` (`"40m"` …) and
  `:flash_size` (`"4MB"` …) default to `:keep`. Binaries that are not images are
  returned unchanged; an appended SHA256 digest is recomputed.
  """
  @spec patch_header(binary(), Chip.name(), keyword()) :: {:ok, binary()} | {:error, term()}
  def patch_header(binary, chip, opts) do
    mode = Keyword.get(opts, :flash_mode, :keep)
    freq = Keyword.get(opts, :flash_freq, :keep)
    size = Keyword.get(opts, :flash_size, :keep)

    case {{mode, freq, size}, parse(binary)} do
      {{:keep, :keep, :keep}, _} ->
        {:ok, binary}

      {_, {:error, _}} ->
        {:ok, binary}

      {_, {:ok, image}} ->
        with {:ok, mode} <- flash_mode_value(mode, image),
             {:ok, freq} <- flash_freq_value(freq, chip, image),
             {:ok, size} <- flash_size_value(size, chip, image) do
          <<head::binary-size(2), _::binary-size(2), rest::binary>> = binary
          {:ok, update_digest(<<head::binary, mode, size <<< 4 ||| freq, rest::binary>>, image)}
        end
    end
  end

  defp flash_mode_value(:keep, image), do: {:ok, image.flash_mode}

  defp flash_mode_value(mode, _image) do
    case Map.fetch(@flash_modes, mode) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:invalid_flash_mode, mode}}
    end
  end

  defp flash_freq_value(:keep, _chip, image), do: {:ok, image.flash_freq}

  defp flash_freq_value(freq, chip, _image) do
    case Chip.flash_freq(chip, freq) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:invalid_flash_freq, freq}}
    end
  end

  defp flash_size_value(:keep, _chip, image), do: {:ok, image.flash_size}

  defp flash_size_value(size, chip, _image) do
    case Chip.flash_size(chip, size) do
      {:ok, value} -> {:ok, value >>> 4}
      :error -> {:error, {:invalid_flash_size, size}}
    end
  end

  # The digest covers everything up to and including the checksum byte
  defp update_digest(binary, %{hash_appended?: true, data_length: length}) do
    case binary do
      <<data::binary-size(^length), _digest::binary-size(@digest_length), rest::binary>> ->
        data <> :crypto.hash(:sha256, data) <> rest

      _ ->
        binary
    end
  end

  defp update_digest(binary, _image), do: binary
end
