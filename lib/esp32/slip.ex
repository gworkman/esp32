defmodule Esp32.SLIP do
  @moduledoc """
  SLIP framing for the ESP serial bootloader.

  Frames are delimited by `0xC0`; `0xC0` and `0xDB` inside a frame are escaped as
  `0xDB 0xDC` and `0xDB 0xDD`. The module also implements `Circuits.UART.Framing`
  so that `Circuits.UART.read/2` yields one decoded frame at a time.
  """

  @behaviour Circuits.UART.Framing

  @end_byte 0xC0
  @esc_byte 0xDB
  @esc_end 0xDC
  @esc_esc 0xDD

  @doc "Encodes `data` as one SLIP frame."
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

  @doc "Unescapes a frame body (the bytes between the delimiters)."
  @spec decode(binary()) :: {:ok, binary()} | {:error, :invalid_escape}
  def decode(body), do: unescape(body, <<>>)

  defp unescape(<<>>, acc), do: {:ok, acc}

  defp unescape(<<@esc_byte, @esc_end, rest::binary>>, acc),
    do: unescape(rest, <<acc::binary, @end_byte>>)

  defp unescape(<<@esc_byte, @esc_esc, rest::binary>>, acc),
    do: unescape(rest, <<acc::binary, @esc_byte>>)

  defp unescape(<<@esc_byte, _::binary>>, _acc), do: {:error, :invalid_escape}
  defp unescape(<<byte, rest::binary>>, acc), do: unescape(rest, <<acc::binary, byte>>)

  # Framing state is nil between frames, or the raw body accumulated so far
  @impl true
  def init(_opts), do: {:ok, nil}

  @impl true
  def add_framing(data, state), do: {:ok, encode(data), state}

  @impl true
  def remove_framing(data, state) do
    {state, frames} = scan(data, state, [])
    {if(state == nil, do: :ok, else: :in_frame), Enum.reverse(frames), state}
  end

  @impl true
  def frame_timeout(_state), do: {:ok, [], nil}

  @impl true
  def flush(_direction, _state), do: nil

  defp scan(data, nil, frames) do
    case :binary.match(data, <<@end_byte>>) do
      :nomatch -> {nil, frames}
      {pos, 1} -> scan(after_byte(data, pos), <<>>, frames)
    end
  end

  defp scan(data, acc, frames) do
    case :binary.match(data, <<@end_byte>>) do
      :nomatch ->
        {acc <> data, frames}

      {pos, 1} ->
        scan(after_byte(data, pos), nil, add_frame(acc <> binary_part(data, 0, pos), frames))
    end
  end

  defp after_byte(data, pos), do: binary_part(data, pos + 1, byte_size(data) - pos - 1)

  defp add_frame(<<>>, frames), do: frames

  defp add_frame(body, frames) do
    case decode(body) do
      {:ok, frame} -> [frame | frames]
      error -> [error | frames]
    end
  end
end
