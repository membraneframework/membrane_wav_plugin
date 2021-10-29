defmodule Membrane.WAV.Common do
  @moduledoc false
  alias Membrane.Caps.Audio.Raw

  @spec convert_to_demand_in_bytes(integer(), integer(), Raw.t()) :: list
  def convert_to_demand_in_bytes(buffers_count, frames_per_buffer, caps) do
    bytes_per_buffer = Raw.frames_to_bytes(frames_per_buffer, caps)
    1..buffers_count |> Enum.flat_map(fn _i -> [demand: {:input, bytes_per_buffer}] end)
  end
end
