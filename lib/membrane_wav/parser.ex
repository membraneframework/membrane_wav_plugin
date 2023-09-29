defmodule Membrane.WAV.Parser do
  @moduledoc """
  Element responsible for parsing WAV files.

  It requires WAV file in uncompressed, PCM format on the input (otherwise error is raised) and
  provides raw audio on the output. WAV header is parsed to extract metadata of the raw audio format.
  Then it is dropped and only samples are sent to the next element.

  The element has one option - `frames_per_buffer`. User can specify number of frames sent in
  one buffer when demand unit on the output is `:buffers`. One frame contains
  `bits per sample * number of channels` bits.

  ## WAV Header

  ```
     0                   4                   8                   12                  16
     _________________________________________________________________________________
  0  |                   |                   |                   |                   |
     |      "RIFF"       |    file length    |      "WAVE"       |       "fmt "      |
     |                   |                   |                   |                   |
     |___________________|___________________|___________________|___________________|
  16 |                   |         |         |                   |                   |
     |   format chunk    | format  |number of|      sample       | data transmission |
     |      length       |(1 - PCM)|channels |       rate        |       rate        |
     |___________________|_________|_________|___________________|___________________|
  32 |  block  |  bits   |                   |                   |                   |
     |  align  |  per    |      "fact"       |     fact chunk    |    samples per    |
     |  unit   | sample  |                   |       length      |      channel      |
     |_________|_________|___________________|___________________|___________________|
  48 |                   |                   |                                       |
     |      "data"       |    data length    |                 DATA                  |
     |                   |     in bytes      |                                       |
     |___________________|___________________|_______________________________________|
  ```
  Header may contain additional bytes between `bits per sample` and `"fact"` in case of `format`
  different from 1 (1 represents PCM / uncompressed format). Length of block from `format` until
  `"fact"` is present in `format chunk length` (it is 16 for PCM).

  Blocks from byte 36 to 48 are optional. There can be additional bytes after `samples per
  channel` if `fact chunk length` contains number bigger than 4.

  ## Parsing

  Stages of parsing:
  - `:init` - Parser waits for the first 16 bytes. After getting them, it parses these bytes
    to ensure that it is a WAV file. After parsing, the stage is set to `:format`.
  - `:format` - Parser waits for the next 28 bytes - Parser  then knows `format chunk length` and `format`,
    so it is able to raise an error in case of different `format` than 1 (PCM) / 3 (IEEE float) or different
    length than 16 (for PCM). Then it parses it and create `Membrane.RawAudio` struct with audio format to send it
    as stream_format to the next element. Stage is set to `:fact` or `:data` depending on last 8 bytes.
  - `:fact` - Parser waits for `8 + fact chunk length` bytes. It  parses them only to check if
    the header is correct, but does not use that data in any way. After parsing, the stage is
    set to `:data`.
  - `:data` - header is already fully parsed. All new data from the input is sent to the output.

  """

  use Membrane.Filter

  alias Membrane.{Buffer, RawAudio, RemoteStream}

  @pcm_format_size 16

  @pcm_format_code 1
  @ieee_float_format_code 3

  @init_stage_size 16
  @format_stage_size 28
  @data_stage_base_size 8

  def_output_pad :output,
    mode: :pull,
    availability: :always,
    demand_mode: :auto,
    accepted_format: RawAudio

  def_input_pad :input,
    mode: :pull,
    availability: :always,
    demand_unit: :bytes,
    demand_mode: :auto,
    accepted_format: RemoteStream

  @impl true
  def handle_init(_ctx, _options) do
    state = %{
      stage: :init,
      next_stage_size: @init_stage_size,
      unparsed_data: ""
    }

    {[], state}
  end

  @impl true
  def handle_stream_format(:input, _format, _context, state) do
    {[], state}
  end

  @impl true
  def handle_process_list(:input, buffers, _context, %{stage: :data} = state) do
    {[buffer: {:output, buffers}], state}
  end

  def handle_process_list(:input, buffers, _context, state) do
    payload =
      buffers
      |> Enum.map(& &1.payload)
      |> then(&[state.unparsed_data | &1])
      |> IO.iodata_to_binary()

    {actions, state} = parse_payload(payload, state)

    {actions, state}
  end

  defp parse_payload(payload, state, actions_acc \\ [])

  defp parse_payload(payload, %{stage: :data} = state, actions_acc) do
    actions =
      [{:buffer, {:output, %Buffer{payload: payload}}} | actions_acc]
      |> Enum.reverse()

    state = %{state | unparsed_data: ""}
    {actions, state}
  end

  defp parse_payload(payload, %{stage: :init} = state, actions_acc)
       when byte_size(payload) >= @init_stage_size do
    <<
      "RIFF",
      _file_size::32-little,
      "WAVE",
      "fmt ",
      rest::binary
    >> = payload

    state = %{state | stage: :format}

    parse_payload(rest, state, actions_acc)
  end

  defp parse_payload(payload, %{stage: :format} = state, actions_acc)
       when byte_size(payload) >= @format_stage_size do
    <<
      format_chunk_size::32-little,
      format_code::16-little,
      channels::16-little,
      sample_rate::32-little,
      _data_transmission_rate::32,
      _block_alignment_unit::16,
      bits_per_sample::16-little,
      next_chunk_type::32-bits,
      next_chunk_size::32-little,
      rest::binary
    >> = payload

    check_format(format_code, format_chunk_size)

    sample_type =
      cond do
        @pcm_format_code -> :s
        @ieee_float_format_code -> :f
      end

    format = %RawAudio{
      channels: channels,
      sample_rate: sample_rate,
      sample_format: RawAudio.SampleFormat.from_tuple({sample_type, bits_per_sample, :le})
    }

    next_stage =
      case next_chunk_type do
        "fact" -> :fact
        "data" -> :data
      end

    acc = [{:stream_format, {:output, format}} | actions_acc]
    state = %{state | stage: next_stage, next_stage_size: next_chunk_size}
    parse_payload(rest, state, acc)
  end

  defp parse_payload(payload, %{stage: :fact, next_stage_size: stage_size} = state, actions_acc)
       when byte_size(payload) >= stage_size + @data_stage_base_size do
    # Ignoring "fact" chunk, for PCM, if present, it only contains a number of samples in file
    <<
      _fact_chunk::binary-size(stage_size),
      "data",
      data_size::32,
      rest::binary
    >> = payload

    state = %{state | stage: :data, next_stage_size: data_size}

    parse_payload(rest, state, actions_acc)
  end

  # Reached only when parsing was stopped before reaching :data stage
  # due to insufficient amount of data
  defp parse_payload(payload, %{stage: stage} = state, actions_acc) when stage != :data do
    state = %{state | unparsed_data: payload}
    {Enum.reverse(actions_acc), state}
  end

  defp check_format(format_code, format_chunk_size) do
    cond do
      format_code not in [1, 3] ->
        raise """
        formats different than PCM and IEEE float are not supported; expected 1 or 3, given #{format_code}; format chunk size: #{format_chunk_size}
        """

      format_chunk_size != @pcm_format_size ->
        raise """
        format chunk size different than supported; expected 16, given #{format_chunk_size}
        """

      true ->
        :ok
    end
  end
end
