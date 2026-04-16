defmodule Esp32.SLIP do
  @moduledoc """
  SLIP (Serial Line Internet Protocol) encoding and decoding for the ESP32 bootloader.

  The ESP32 bootloader uses SLIP framing to delimit packets.
  - `0xC0` is used as the end-of-frame marker.
  - `0xDB` is the escape character.
  - `0xDB 0xDC` encodes a literal `0xC0`.
  - `0xDB 0xDD` encodes a literal `0xDB`.
  """

  @end_byte 0xC0
  @esc_byte 0xDB
  @esc_end 0xDC
  @esc_esc 0xDD

  @doc """
  Encodes a binary into a SLIP-framed packet.

  Wraps the data with `0xC0` and escapes any occurrences of `0xC0` or `0xDB`
  within the payload.
  """
  @spec encode(binary()) :: binary()
  def encode(data) do
    escaped =
      for <<byte <- data>>, into: <<>> do
        case byte do
          @end_byte -> <<@esc_byte, @esc_end>>
          @esc_byte -> <<@esc_byte, @esc_esc>>
          _ -> <<byte>>
        end
      end

    <<@end_byte, escaped::binary, @end_byte>>
  end

  @doc """
  Decodes a SLIP-framed packet.

  Removes the `0xC0` framing and unescapes any encoded characters.

  Returns `{:ok, decoded_data}` if successful, or `{:error, reason}`.
  """
  @spec decode(binary()) :: {:ok, binary()} | {:error, :invalid_escape}
  def decode(packet) do
    # Remove leading/trailing C0 if present
    trimmed = trim_frame(packet)
    unescape(trimmed, <<>>)
  end

  defp trim_frame(<<@end_byte, rest::binary>>) do
    if byte_size(rest) > 0 and binary_part(rest, byte_size(rest) - 1, 1) == <<@end_byte>> do
      binary_part(rest, 0, byte_size(rest) - 1)
    else
      rest
    end
  end

  defp trim_frame(packet), do: packet

  defp unescape(<<>>, acc), do: {:ok, acc}

  defp unescape(<<@esc_byte, @esc_end, rest::binary>>, acc) do
    unescape(rest, <<acc::binary, @end_byte>>)
  end

  defp unescape(<<@esc_byte, @esc_esc, rest::binary>>, acc) do
    unescape(rest, <<acc::binary, @esc_byte>>)
  end

  defp unescape(<<@esc_byte, _::binary>>, _acc), do: {:error, :invalid_escape}

  defp unescape(<<byte, rest::binary>>, acc) do
    unescape(rest, <<acc::binary, byte>>)
  end
end
