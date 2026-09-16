defmodule Esp32.Device do
  @moduledoc """
  A connected ESP device, as returned by `Esp32.connect/2`.
  """

  @type t :: %__MODULE__{
          uart: pid(),
          port: String.t() | nil,
          chip: Esp32.Chip.name() | nil,
          baud: pos_integer(),
          stub?: boolean(),
          usb_otg?: boolean()
        }

  defstruct [:uart, :port, :chip, baud: 115_200, stub?: false, usb_otg?: false]
end
