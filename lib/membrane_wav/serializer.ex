defmodule Membrane.WAV.Serializer do
  use Membrane.Filter

  alias Membrane.Buffer
  alias Membrane.Caps.Audio.Raw, as: Caps
  alias Membrane.Caps.Audio.Raw.Format

  @file_length 0
  @data_length 0

  def_options frames_per_buffer: [
                type: :integer,
                spec: pos_integer(),
                description: """
                Assumed number of raw audio frames in each buffer.
                Used when converting demand from buffers into bytes.
                """,
                default: 2048
              ]

  def_output_pad :output,
    mode: :pull,
    availability: :always,
    caps: Caps

  def_input_pad :input,
    mode: :pull,
    availability: :always,
    demand_unit: :bytes,
    caps: Caps

  @impl true
  def handle_init(state) do
    state = Map.put(state, :header_created, false)

    {:ok, state}
  end

  @impl true
  def handle_caps(:input, caps, _context, state) do
    buffer = create_header(caps)
    state = Map.merge(state, %{header_created: true, caps: caps})

    {{:ok, caps: caps, buffer: {:output, buffer}, redemand: :output}, state}
  end

  @impl true
  def handle_demand(:output, _size, _unit, _context, %{header_created: false} = state) do
    {:ok, state}
  end

  def handle_demand(:output, size, :bytes, _context, %{header_created: true} = state) do
    {{:ok, demand: {:input, size}}, state}
  end

  def handle_demand(
        :output,
        buffers_count,
        :buffers,
        _context,
        %{header_created: true, frames_per_buffer: frames, caps: caps} = state
      ) do
    size = buffers_count * Caps.frames_to_bytes(frames, caps)

    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_process(:input, buffer, _context, state) do
    {{:ok, buffer: {:output, buffer}}, state}
  end

  defp create_header(%Caps{channels: channels, sample_rate: sample_rate, format: format}) do
    {_signedness, bits_per_sample, _endianness} = Format.to_tuple(format)

    format_chunk_length = 16
    audio_format = 1
    data_transmission_rate = ceil(channels * sample_rate * bits_per_sample / 8)
    block_alignment_unit = ceil(channels * bits_per_sample / 8)

    header = <<
      "RIFF",
      @file_length::32-little,
      "WAVE",
      "fmt ",
      format_chunk_length::32-little,
      audio_format::16-little,
      channels::16-little,
      sample_rate::32-little,
      data_transmission_rate::32-little,
      block_alignment_unit::16-little,
      bits_per_sample::16-little,
      "data",
      @data_length::32-little
    >>

    %Buffer{payload: header}
  end
end
