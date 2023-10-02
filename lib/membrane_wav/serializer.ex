defmodule Membrane.WAV.Serializer do
  @moduledoc """
  Element responsible for raw audio serialization to WAV format.

  Creates WAV header (its description can be found with `Membrane.WAV.Parser`) based on a format received in stream_format and puts it before audio samples. The element assumes that audio is in PCM format.

  `file length` and `data length` fields can be calculated only after processing all samples, so
  the serializer uses `Membrane.File.SeekSinkEvent` to supply them with proper values before the end
  of stream. If your sink doesn't support seeking, set `disable_seeking` option to `true` and fix
  the header using `Membrane.WAV.Postprocessing`.
  """

  use Membrane.Filter

  alias Membrane.{Buffer, RawAudio}

  @file_length 0
  @data_length 0

  @pcm_format_code 1
  @ieee_float_format_code 3

  @format_chunk_length 16

  @file_length_offset 4
  @data_length_offset 40

  def_options disable_seeking: [
                spec: boolean(),
                description: """
                Whether the element should disable emitting `Membrane.File.SeekEvent`.

                The event is used to supply the WAV header with proper values before
                the end of stream. If your sink doesn't support it, you should set this
                option to `true` and use `Membrane.WAV.Postprocessing` to fix the header.
                """,
                default: false
              ]

  def_output_pad :output,
    mode: :pull,
    demand_mode: :auto,
    availability: :always,
    accepted_format: _any

  def_input_pad :input,
    mode: :pull,
    availability: :always,
    demand_unit: :bytes,
    demand_mode: :auto,
    accepted_format: RawAudio

  @impl true
  def handle_init(_ctx, options) do
    state =
      options
      |> Map.from_struct()
      |> Map.merge(%{
        header_length: 0,
        data_length: 0
      })

    {[], state}
  end

  @impl true
  def handle_stream_format(:input, format, _context, state) do
    buffer = %Buffer{payload: create_header(format)}
    # subtracting 8 bytes as header length doesn't include "RIFF" and `file_length` fields
    state = Map.put(state, :header_length, byte_size(buffer.payload) - 8)

    {[stream_format: {:output, format}, buffer: {:output, buffer}], state}
  end

  @impl true
  def handle_process_list(:input, _buffers, _context, %{header_length: 0}) do
    raise "Buffers received before format, cannot create the header"
  end

  def handle_process_list(:input, buffers, _context, %{data_length: data_length} = state) do
    data_length =
      Enum.reduce(buffers, data_length, fn %Buffer{payload: payload}, acc ->
        acc + byte_size(payload)
      end)

    state = Map.put(state, :data_length, data_length)

    {[buffer: {:output, buffers}], state}
  end

  @impl true
  def handle_end_of_stream(:input, _context, state) do
    actions = maybe_update_header_actions(state) ++ [end_of_stream: :output]
    {actions, state}
  end

  defp create_header(%RawAudio{
         channels: channels,
         sample_rate: sample_rate,
         sample_format: format
       }) do
    {sample_type, bits_per_sample, _endianness} = RawAudio.SampleFormat.to_tuple(format)

    data_transmission_rate = ceil(channels * sample_rate * bits_per_sample / 8)
    block_alignment_unit = ceil(channels * bits_per_sample / 8)

    format_code =
      case sample_type do
        :f -> @ieee_float_format_code
        _pcm -> @pcm_format_code
      end

    <<
      "RIFF",
      @file_length::32-little,
      "WAVE",
      "fmt ",
      @format_chunk_length::32-little,
      format_code::16-little,
      channels::16-little,
      sample_rate::32-little,
      data_transmission_rate::32-little,
      block_alignment_unit::16-little,
      bits_per_sample::16-little,
      "data",
      @data_length::32-little
    >>
  end

  defp maybe_update_header_actions(%{disable_seeking: true}), do: []

  if Code.ensure_loaded?(Membrane.File.SeekSourceEvent) do
    defp maybe_update_header_actions(%{header_length: header_length, data_length: data_length}) do
      file_length = header_length + data_length

      [
        event: {:output, %Membrane.File.SeekSinkEvent{position: @file_length_offset}},
        buffer: {:output, %Buffer{payload: <<file_length::32-little>>}},
        event: {:output, %Membrane.File.SeekSinkEvent{position: @data_length_offset}},
        buffer: {:output, %Buffer{payload: <<data_length::32-little>>}}
      ]
    end
  else
    defp maybe_update_header_actions(_state) do
      raise """
      Unable to update WAV header as `Membrane.File.SeekEvent` module is not available.
      Set `disable_seeking` option to `true` and fix the header using `Membrane.WAV.Postprocessing`
      or use a sink that supports seeking (e.g. `Membrane.File.Sink`).
      """
    end
  end
end
