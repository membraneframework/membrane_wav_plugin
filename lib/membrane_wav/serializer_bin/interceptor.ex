defmodule Membrane.WAV.SerializerBin.Interceptor do
  @moduledoc false

  # The element tracks info about payload sizes, then updates WAV header using `Membrane.File.SeekEvent`.

  use Membrane.Filter

  alias Membrane.{Buffer, File}

  @file_length_offset 4
  @data_length_offset 40

  def_input_pad :input, demand_unit: :buffers, caps: :any

  def_output_pad :output, caps: :any

  @impl true
  def handle_init(_options) do
    {:ok, %{header_length: 0, data_length: 0}}
  end

  @impl true
  def handle_caps(:input, caps, _context, state) do
    {{:ok, caps: {:output, caps}}, state}
  end

  @impl true
  def handle_demand(:output, size, _unit, _context, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_process(:input, buffer, _context, %{header_length: 0} = state) do
    state = Map.put(state, :header_length, byte_size(buffer.payload))
    {{:ok, buffer: {:output, buffer}, redemand: :output}, state}
  end

  def handle_process(:input, buffer, _context, state) do
    state = Map.put(state, :data_length, state.data_length + byte_size(buffer.payload))
    {{:ok, buffer: {:output, buffer}, redemand: :output}, state}
  end

  @impl true
  def handle_end_of_stream(
        :input,
        _context,
        %{header_length: header_length, data_length: data_length} = state
      ) do
    file_length = header_length + data_length

    actions = [
      event: {:output, %File.SeekEvent{position: @file_length_offset}},
      buffer: {:output, %Buffer{payload: <<file_length::32-little>>}},
      event: {:output, %File.SeekEvent{position: @data_length_offset}},
      buffer: {:output, %Buffer{payload: <<data_length::32-little>>}},
      end_of_stream: :output
    ]

    {{:ok, actions}, state}
  end
end
