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
          usb_otg?: boolean(),
          reset: Esp32.Reset.strategy(),
          reset_pin: term(),
          boot_pin: term()
        }

  defstruct [
    :uart,
    :port,
    :chip,
    :reset_pin,
    :boot_pin,
    baud: 115_200,
    stub?: false,
    usb_otg?: false,
    reset: :none
  ]
end
