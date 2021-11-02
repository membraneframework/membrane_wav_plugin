defmodule Membrane.WAV.Common do
  @moduledoc false
  alias Membrane.Caps.Audio.Raw
  alias Membrane.Element.Action

  @spec convert_to_demand_in_bytes(integer(), integer(), Raw.t()) :: [Action.demand_t()]
  def convert_to_demand_in_bytes(buffers_count, frames_per_buffer, caps) do
    bytes_per_buffer = Raw.frames_to_bytes(frames_per_buffer, caps)
    List.duplicate({:demand, {:input, bytes_per_buffer}}, buffers_count)
  end
end
