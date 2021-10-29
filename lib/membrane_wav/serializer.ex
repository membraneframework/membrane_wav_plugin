defmodule Membrane.WAV.Serializer do
  @moduledoc """
  Element responsible for raw audio serialization to WAV format.

  Creates WAV header (its description can be found with `Membrane.WAV.Parser`) from received caps
  and puts it before audio samples. The element assumes that audio is in PCM format. `File length`
  and `data length` can be calculated only after processing all samples, so these values are
  invalid (always set to 0). Use `Membrane.WAV.Postprocessing.fix_wav_header/1` module to fix them.

  The element has one option - `frames_per_buffer`. User can specify number of frames sent in one
  buffer when demand unit on the output is `:buffers`. One frame contains `bits per sample` x
  `number of channels` bits.
  """

  use Membrane.Filter

  alias Membrane.Buffer
  alias Membrane.Caps.Audio.Raw, as: Caps
  alias Membrane.Caps.Audio.Raw.Format
  alias Membrane.WAV.Common

  @file_length 0
  @data_length 0

  @audio_format 1
  @format_chunk_length 16

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
    caps: :any

  def_input_pad :input,
    mode: :pull,
    availability: :always,
    demand_unit: :bytes,
    caps: Caps

  @impl true
  def handle_init(options) do
    state =
      options
      |> Map.from_struct()
      |> Map.put(:header_created, false)

    {:ok, state}
  end

  @impl true
  def handle_caps(:input, caps, _context, state) do
    buffer = %Buffer{payload: create_header(caps)}
    state = %{state | header_created: true}

    {{:ok, caps: {:output, caps}, buffer: {:output, buffer}, redemand: :output}, state}
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
        context,
        %{header_created: true, frames_per_buffer: frames} = state
      ) do
    caps = context.pads.output.caps
    demands = Common.convert_to_demand_in_bytes(buffers_count, frames, caps)
    {{:ok, demands}, state}
  end

  @impl true
  def handle_process(:input, buffer, _context, %{header_created: true} = state) do
    {{:ok, buffer: {:output, buffer}}, state}
  end

  def handle_process(:input, _buffer, _context, %{header_created: false}) do
    raise(RuntimeError, "buffer received before caps, so the header is not created yet")
  end

  defp create_header(%Caps{channels: channels, sample_rate: sample_rate, format: format}) do
    {_signedness, bits_per_sample, _endianness} = Format.to_tuple(format)

    data_transmission_rate = ceil(channels * sample_rate * bits_per_sample / 8)
    block_alignment_unit = ceil(channels * bits_per_sample / 8)

    <<
      "RIFF",
      @file_length::32-little,
      "WAVE",
      "fmt ",
      @format_chunk_length::32-little,
      @audio_format::16-little,
      channels::16-little,
      sample_rate::32-little,
      data_transmission_rate::32-little,
      block_alignment_unit::16-little,
      bits_per_sample::16-little,
      "data",
      @data_length::32-little
    >>
  end
end
