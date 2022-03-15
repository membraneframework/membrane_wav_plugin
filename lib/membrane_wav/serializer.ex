defmodule Membrane.WAV.Serializer do
  @moduledoc """
  Element responsible for raw audio serialization to WAV format.

  Creates WAV header (its description can be found with `Membrane.WAV.Parser`) from received caps
  and puts it before audio samples. The element assumes that audio is in PCM format. `File length`
  and `data length` can be calculated only after processing all samples, so these values are
  invalid (always set to 0). Save the file using `Membrane.File.Sink` to avoid this problem, or
  `Membrane.WAV.Postprocessing.fix_wav_header/1` module to fix it afterwards.

  The element has one option - `frames_per_buffer`. User can specify number of frames sent in one
  buffer when demand unit on the output is `:buffers`. One frame contains `bits per sample` x
  `number of channels` bits.
  """

  use Membrane.Filter

  alias Membrane.Buffer
  alias Membrane.Caps.Audio.Raw, as: Caps
  alias Membrane.Caps.Audio.Raw.Format

  @file_length 0
  @data_length 0

  @audio_format 1
  @format_chunk_length 16

  @file_length_offset 4
  @data_length_offset 40

  def_options frames_per_buffer: [
                type: :integer,
                spec: pos_integer(),
                description: """
                Assumed number of raw audio frames in each buffer.
                Used when converting demand from buffers into bytes.
                """,
                default: 2048
              ],
              update_header?: [
                spec: boolean(),
                description: """
                Whether the element should use `Membrane.File.SeekEvent` to update the
                WAV header with valid information. Requires dependency on `Membrane.File`.

                If your pipeline can't output the file by `Membrane.File.Sink`, it is
                recommended to turn this option off and use `Membrane.WAV.Postprocessing`
                to fix the header afterwards.
                """,
                default: true
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
      |> Map.merge(%{
        header_length: 0,
        data_length: 0
      })

    {:ok, state}
  end

  @impl true
  def handle_caps(:input, caps, _context, state) do
    buffer = %Buffer{payload: create_header(caps)}
    state = %{state | header_length: byte_size(buffer.payload)}
    {{:ok, caps: {:output, caps}, buffer: {:output, buffer}, redemand: :output}, state}
  end

  @impl true
  def handle_demand(:output, _size, _unit, _context, %{header_length: 0} = state) do
    {:ok, state}
  end

  def handle_demand(:output, size, :bytes, _context, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  def handle_demand(
        :output,
        buffers_count,
        :buffers,
        context,
        %{frames_per_buffer: frames} = state
      ) do
    caps = context.pads.output.caps
    demand_size = Caps.frames_to_bytes(frames, caps) * buffers_count
    {{:ok, demand: {:input, demand_size}}, state}
  end

  @impl true
  def handle_process_list(:input, _buffers, _context, %{header_length: 0}) do
    raise(RuntimeError, "buffers received before caps, so the header is not created yet")
  end

  def handle_process_list(:input, buffers, _context, %{data_length: data_length} = state) do
    state =
      buffers
      |> Enum.reduce(data_length, fn %Buffer{payload: payload}, acc ->
        acc + byte_size(payload)
      end)
      |> then(&Map.put(state, :data_length, &1))

    {{:ok, buffer: {:output, [buffers]}, redemand: :output}, state}
  end

  @impl true
  def handle_end_of_stream(:input, _context, state) do
    actions = maybe_update_header_actions(state) ++ [end_of_stream: :output]
    {{:ok, actions}, state}
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

  defp maybe_update_header_actions(%{update_header?: false}), do: []

  defp maybe_update_header_actions(%{header_length: header_length, data_length: data_length}) do
    case Code.ensure_compiled(Membrane.File.SeekEvent) do
      {:module, seek_event} ->
        # subtracting 8 bytes as `file_length` field doesn't include "RIFF" header and the field itself
        file_length = header_length + data_length - 8

        [
          event: {:output, struct!(seek_event, position: @file_length_offset)},
          buffer: {:output, %Buffer{payload: <<file_length::32-little>>}},
          event: {:output, struct!(seek_event, position: @data_length_offset)},
          buffer: {:output, %Buffer{payload: <<data_length::32-little>>}}
        ]

      {:error, reason} ->
        require Membrane.Logger

        Membrane.Logger.warn("""
        Couldn't update WAV header as `Membrane.File.SeekEvent` module is not available (reason: #{inspect(reason)}).
        You can use `Membrane.File.Sink` in your pipeline to correctly save the file or fix it later using
        `Membrane.WAV.Postprocessing`.
        """)

        []
    end
  end
end
